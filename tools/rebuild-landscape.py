#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
rebuild-landscape.py — 把「一键横屏」改动重新套到官方新版上

背景
----
「一键横屏」是一份很小的改动：1 个全新文件 public/js/ui/landscape.js，外加十几个
已有文件的小修改，打包成 17 个文件的补丁包（stronghold-vX.Y.Z-landscape-patch.tar.gz）。
它和它所基于的版本是**绑定**的：补丁包里的 MANIFEST.json 记录着那一版每个文件的
size/sha256，服务端更新校验也按版本进行。所以官方一发新版，旧补丁**不能**直接套用。

这个工具把这份改动「重新基于」新版之上：

    base   = 补丁包当初对应的官方版本（从补丁包自带 MANIFEST.json 的 app 字段读出）
    ours   = 横屏补丁包（我们改过的那 17 个文件）
    theirs = 官方新版完整包（.tar.gz 或官方发行的 .zip 都行）

对「两边都改过」的文件做三方合并（git merge-file）；横屏新增的文件原样带过去；
按新版重算 MANIFEST.json；然后输出：

    stronghold-v<newver>-landscape-patch.tar.gz   增量补丁包（配 deploy-landscape-patch.sh）
    stronghold-v<newver>-full-landscape.tar.gz    横屏完整包（配 deploy-landscape.sh）

冲突会用 diff3 标记写进工作目录，工具会**停下来**等你手工改完再打包（改完用
--resolved 重跑）。合并出的 .js 会做 node --check 语法检查，.json 会做解析检查。

用法
----
    python rebuild-landscape.py --ours <横屏补丁包> [--new <官方新版完整包>]
        [--base <官方旧版完整包>] [--dir <搜索目录>] [--out-dir <输出目录>]
        [--work-dir <工作目录>] [--resolved] [--force] [--fast]

官方新版是 Stronghold-Protocol-vX.Y.Z.zip 时，--new 直接给这个 zip 即可；
不指定 --new 时，也会自动找 --dir 里的 stronghold-v*-full.tar.gz 或 Stronghold-Protocol-v*.zip。

典型：把官方新版完整包和横屏补丁包都放进 F:\\dsharness\\downloads，然后
    python rebuild-landscape.py --ours F:\\dsharness\\downloads\\stronghold-v0.3.3-landscape-patch.tar.gz
（--base / --new 会自动在 --dir 里找）

依赖：python3、git（用于 git merge-file）、node（可选，用于语法检查）。
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile

MANIFEST_REL = "MANIFEST.json"
FULL_RE = re.compile(r"^stronghold-v(?P<v>.+)-full\.tar\.gz$")
ZIP_RE = re.compile(r"^Stronghold-Protocol-v(?P<v>.+)\.zip$", re.IGNORECASE)


# ----------------------------------------------------------------------------- 基础工具

def norm(name: str) -> str:
    n = name.replace("\\", "/")
    while n.startswith("./"):
        n = n[2:]
    return n.lstrip("/")


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def say(msg: str) -> None:
    print(msg, flush=True)


def warn(msg: str) -> None:
    print("[!] " + msg, flush=True)


def die(msg: str) -> "None":
    print("[x] " + msg, file=sys.stderr, flush=True)
    sys.exit(1)


def read_tar(path, wanted=None):
    """读取一个 tar.gz，返回 (files, infos)。wanted 为 rel 集合时只取这些成员。"""
    files, infos = {}, {}
    with tarfile.open(path, "r:gz") as t:
        for m in t:
            if not m.isfile():
                continue
            rel = norm(m.name)
            if wanted is not None and rel not in wanted:
                continue
            fh = t.extractfile(m)
            files[rel] = fh.read() if fh is not None else b""
            infos[rel] = m
    return files, infos


def zip_prefix(names):
    """官方 zip 里所有文件都在一个顶层目录（Stronghold-Protocol/）下：返回该前缀。"""
    tops = {n.split("/", 1)[0] for n in names if "/" in n}
    return (next(iter(tops)) + "/") if len(tops) == 1 else ""


def read_zip(path, wanted=None):
    """读取官方 .zip（自动去掉顶层目录），返回 (files, infos)。"""
    files, infos = {}, {}
    with zipfile.ZipFile(path) as z:
        names = [n for n in z.namelist() if not n.endswith("/")]
        prefix = zip_prefix(names)
        for n in names:
            rel = norm(n[len(prefix):] if prefix and n.startswith(prefix) else n)
            if wanted is not None and rel not in wanted:
                continue
            files[rel] = z.read(n)
            infos[rel] = None
    return files, infos


def read_package(path, wanted=None):
    """tar.gz 或官方 .zip 都能读。"""
    if path.lower().endswith(".zip"):
        return read_zip(path, wanted)
    return read_tar(path, wanted)


# ----------------------------------------------------------------------------- 三方合并

def merge3(rel: str, base: bytes, ours: bytes, theirs: bytes, git: str):
    """三方合并，返回 (merged_bytes, conflict_count)。conflict_count<0 表示工具出错。"""
    if ours == theirs:
        return ours, 0
    if theirs == base:
        return ours, 0
    if ours == base:
        return theirs, 0
    if git:
        with tempfile.TemporaryDirectory() as d:
            fn = {}
            for k, data in (("ours", ours), ("base", base), ("theirs", theirs)):
                fn[k] = os.path.join(d, k)
                with open(fn[k], "wb") as fh:
                    fh.write(data)
            p = subprocess.run(
                [git, "merge-file", "-p", "--diff3",
                 "-L", "ours", "-L", "base", "-L", "theirs",
                 fn["ours"], fn["base"], fn["theirs"]],
                capture_output=True,
            )
            if p.returncode < 0:
                warn(f"git merge-file 出错（{rel}），退回到粗暴合并")
                return _crude(base, ours, theirs), 1
            return p.stdout, p.returncode
    return _crude(base, ours, theirs), 1


def _crude(base: bytes, ours: bytes, theirs: bytes):
    return (b"<<<<<<< ours\n" + ours + b"||||||| base\n" + base
            + b"=======\n" + theirs + b">>>>>>> theirs\n")


# ----------------------------------------------------------------------------- MANIFEST

def serialize_manifest(mf: dict) -> str:
    """按项目原格式序列化 MANIFEST.json：{"format":N,"app":"x","files":{\\n ... \\n}}\\n"""
    parts = []
    for k, v in mf["files"].items():
        parts.append(json.dumps(k, ensure_ascii=False)
                     + ':{"size":' + str(int(v["size"])) + ',"sha256":"' + v["sha256"] + '"}')
    return ('{"format":' + str(mf["format"]) + ',"app":' + json.dumps(mf["app"], ensure_ascii=False)
            + ',"files":{\n' + ",\n".join(parts) + "\n}}\n")


def build_manifest(new_bytes: bytes, updates: dict):
    """以新版 MANIFEST.json 为基础，更新 updates={rel:(size,sha)} 对应的条目。

    先尝试结构化重建（要求能原样 round-trip 新版清单，保证格式没变）；不行则退回到
    逐条文本替换（只改这些条目，其余字节不变）。返回 (bytes, mode)。
    """
    orig = new_bytes.decode("utf-8")
    mf = json.loads(orig)
    structured_ok = False
    try:
        structured_ok = (serialize_manifest(json.loads(orig)) == orig)
    except Exception:
        structured_ok = False

    if structured_ok:
        was_sorted = list(mf["files"].keys()) == sorted(mf["files"].keys())
        for rel, (size, sha) in updates.items():
            mf["files"][rel] = {"size": size, "sha256": sha}
        if was_sorted:  # 官方清单是按路径排序的：新增条目插到正确的排序位置
            mf["files"] = {k: mf["files"][k] for k in sorted(mf["files"])}
        return serialize_manifest(mf).encode("utf-8"), "structured"

    # 文本替换兜底：格式与旧版不同时，只改动了的那几条
    warn("新版 MANIFEST.json 的格式与预期不同，改用文本替换（只改这些条目）")
    text = orig
    missing = []
    for rel, (size, sha) in updates.items():
        key = json.dumps(rel, ensure_ascii=False)
        pat = re.compile(re.escape(key) + r':\s*\{"size":\d+,"sha256":"[0-9a-fA-F]{64}"\}')
        repl = key + ':{"size":' + str(size) + ',"sha256":"' + sha + '"}'
        text, n = pat.subn(lambda _m, r=repl: r, text)
        if n == 0:
            missing.append((rel, repl))
    for rel, repl in missing:
        stripped = text.rstrip()
        if not stripped.endswith("}}"):
            die(f"无法把新条目 {rel} 插入 MANIFEST.json（格式无法识别）")
        head = stripped[:-2]
        if head.rstrip().endswith("{"):
            text = head + repl + "\n}}\n"
        else:
            text = head.rstrip() + ",\n" + repl + "\n}}\n"
    return text.encode("utf-8"), "text"


# ----------------------------------------------------------------------------- 自动定位

def find_new(search_dir: str, exclude, origin: str):
    cands = []
    try:
        names = os.listdir(search_dir)
    except OSError:
        return None
    for name in names:
        m = FULL_RE.match(name) or ZIP_RE.match(name)
        if not m:
            continue
        p = os.path.abspath(os.path.join(search_dir, name))
        if p in exclude:
            continue
        if m.group("v") == origin:
            continue
        cands.append((os.path.getmtime(p), p))
    if not cands:
        return None
    cands.sort(reverse=True)
    return cands[0][1]


# ----------------------------------------------------------------------------- 打包

def write_patch_bundle(path: str, our_order, our_infos, payload: dict) -> None:
    with tarfile.open(path, "w:gz", format=tarfile.PAX_FORMAT) as dst:
        for rel in our_order:
            data = payload[rel]
            info = our_infos.get(rel)
            if info is None:
                info = tarfile.TarInfo("./" + rel)
                info.mode = 0o644
                info.mtime = int(time.time())
            info.size = len(data)
            dst.addfile(info, io.BytesIO(data))


def write_full_package(path: str, new_path: str, payload: dict, order_for_append) -> int:
    """流式改写官方新版：payload 里的成员替换掉，其余逐字节照抄；新成员追加在末尾。"""
    if new_path.lower().endswith(".zip"):
        return _write_full_from_zip(path, new_path, payload, order_for_append)

    appended = 0
    seen = set()
    with tarfile.open(new_path, "r:gz") as src, \
            tarfile.open(path, "w:gz", format=tarfile.PAX_FORMAT) as dst:
        for m in src:
            if not m.isfile():
                dst.addfile(m)
                continue
            rel = norm(m.name)
            if rel in payload:
                data = payload[rel]
                m.size = len(data)
                dst.addfile(m, io.BytesIO(data))
                seen.add(rel)
            else:
                fh = src.extractfile(m)
                dst.addfile(m, fh if fh is not None else io.BytesIO(b""))
        for rel in order_for_append:
            if rel in seen or rel not in payload:
                continue
            data = payload[rel]
            ti = tarfile.TarInfo("./" + rel)
            ti.size = len(data)
            ti.mode = 0o644
            ti.mtime = int(time.time())
            dst.addfile(ti, io.BytesIO(data))
            appended += 1
    return appended


def _write_full_from_zip(path: str, new_path: str, payload: dict, order_for_append) -> int:
    """同上，但官方包是 .zip：逐条流式写进 tar.gz（不把大文件整块读进内存）。"""
    appended = 0
    seen = set()
    now = int(time.time())
    with zipfile.ZipFile(new_path) as z, \
            tarfile.open(path, "w:gz", format=tarfile.PAX_FORMAT) as dst:
        names = [n for n in z.namelist() if not n.endswith("/")]
        prefix = zip_prefix(names)
        for n in names:
            rel = norm(n[len(prefix):] if prefix and n.startswith(prefix) else n)
            ti = tarfile.TarInfo("./" + rel)
            ti.mode = 0o644
            ti.mtime = now
            if rel in payload:
                data = payload[rel]
                ti.size = len(data)
                dst.addfile(ti, io.BytesIO(data))
                seen.add(rel)
            else:
                ti.size = z.getinfo(n).file_size
                with z.open(n) as src:
                    dst.addfile(ti, src)
        for rel in order_for_append:
            if rel in seen or rel not in payload:
                continue
            data = payload[rel]
            ti = tarfile.TarInfo("./" + rel)
            ti.size = len(data)
            ti.mode = 0o644
            ti.mtime = now
            dst.addfile(ti, io.BytesIO(data))
            appended += 1
    return appended


# ----------------------------------------------------------------------------- 主流程

def main(argv=None):
    ap = argparse.ArgumentParser(
        description="把「一键横屏」改动重新套到官方新版上（三方合并 + 重算 MANIFEST + 重打包）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--ours", required=True, help="横屏补丁包 stronghold-v*-landscape-patch.tar.gz")
    ap.add_argument("--new", help="官方新版完整包 stronghold-v*-full.tar.gz 或 Stronghold-Protocol-v*.zip（缺省自动查找）")
    ap.add_argument("--base", help="官方旧版完整包 .tar.gz/.zip（缺省按补丁包版本自动查找）")
    ap.add_argument("--dir", help="自动查找 base/new 的目录（缺省为 --ours 所在目录）")
    ap.add_argument("--out-dir", help="输出目录（缺省同 --dir）")
    ap.add_argument("--work-dir", help="工作目录（缺省 <out-dir>/_rebuild-v<newver>）")
    ap.add_argument("--resolved", action="store_true", help="不再合并，直接用工作目录里已修好的文件打包")
    ap.add_argument("--force", action="store_true", help="有冲突/检查失败也照常打包")
    ap.add_argument("--fast", action="store_true", help="跳过对输出完整包的复查（少解压一次 780MB）")
    ap.add_argument("--no-check", action="store_true", help="跳过 node --check / JSON 解析检查")
    ap.add_argument("--no-scripts", action="store_true", help="不把版本无关的部署脚本复制到输出目录")
    args = ap.parse_args(argv)

    ours_path = os.path.abspath(args.ours)
    if not os.path.isfile(ours_path):
        die(f"找不到横屏补丁包：{ours_path}")
    search_dir = os.path.abspath(args.dir or os.path.dirname(ours_path))
    out_dir = os.path.abspath(args.out_dir or search_dir)
    os.makedirs(out_dir, exist_ok=True)

    say("== 读取横屏补丁包（ours）==")
    our_files, our_infos = read_package(ours_path)
    if MANIFEST_REL not in our_files:
        die("补丁包里没有 MANIFEST.json，不像横屏补丁包")
    if "public/js/ui/landscape.js" not in our_files:
        die("补丁包里没有 public/js/ui/landscape.js，不像横屏补丁包")
    our_manifest = json.loads(our_files[MANIFEST_REL].decode("utf-8"))
    origin = str(our_manifest.get("app", "")).strip()
    if not origin:
        die("补丁包 MANIFEST.json 里没有 app 版本号")
    merge_rels = [r for r in our_files if r != MANIFEST_REL]
    our_order = list(our_files.keys())
    say(f"   {ours_path}")
    say(f"   改动集 {len(our_files)} 个文件（{len(merge_rels)} 个已有文件 + 1 个新增），基于官方 v{origin}")

    say("== 读取基准完整包（base）==")
    base_path = os.path.abspath(args.base) if args.base else os.path.join(search_dir, f"stronghold-v{origin}-full.tar.gz")
    if not args.base and not os.path.isfile(base_path):
        alt = os.path.join(search_dir, f"Stronghold-Protocol-v{origin}.zip")
        if os.path.isfile(alt):
            base_path = alt
    if not os.path.isfile(base_path):
        die(f"找不到基准完整包 {base_path}\n    请把官方 v{origin} 完整包（stronghold-v{origin}-full.tar.gz 或 Stronghold-Protocol-v{origin}.zip）放到 {search_dir}，或用 --base 指定")
    base_files, _ = read_package(base_path, wanted=set(merge_rels))
    say(f"   {base_path}")

    say("== 读取官方新版完整包（theirs）==")
    if args.new:
        new_path = os.path.abspath(args.new)
    else:
        new_path = find_new(search_dir, {os.path.abspath(ours_path), base_path}, origin)
    if not new_path or not os.path.isfile(new_path):
        die(f"找不到官方新版完整包。请下载后放到 {search_dir}，或用 --new 指定")
    new_files, new_infos = read_package(new_path, wanted=set(our_order))
    if MANIFEST_REL not in new_files:
        die("新版完整包里没有 MANIFEST.json")
    new_manifest = json.loads(new_files[MANIFEST_REL].decode("utf-8"))
    newver = str(new_manifest.get("app", "")).strip()
    if not newver:
        die("新版 MANIFEST.json 里没有 app 版本号")
    say(f"   {new_path}")
    if newver == origin:
        warn(f"新版版本号与基准相同（都是 v{origin}）—— 这是在重打包同一版？继续，但请确认包没选错")

    work = os.path.abspath(args.work_dir or os.path.join(out_dir, f"_rebuild-v{newver}"))
    merged, conflicts = {}, {}

    if args.resolved:
        say(f"== --resolved：使用工作目录里已修好的文件：{work} ==")
        if not os.path.isdir(work):
            die(f"工作目录不存在：{work}")
        missing = []
        for rel in merge_rels:
            p = os.path.join(work, *rel.split("/"))
            if os.path.isfile(p):
                with open(p, "rb") as fh:
                    merged[rel] = fh.read()
            else:
                missing.append(rel)
        if missing:
            die("工作目录里缺少这些文件：" + ", ".join(missing))
        for rel in merge_rels:
            conflicts[rel] = 1 if b"<<<<<<<" in merged[rel] else 0

        say("== 按新版重算 MANIFEST.json ==")
        updates = {rel: (len(data), sha256_hex(data)) for rel, data in merged.items()}
        manifest_bytes, mode = build_manifest(new_files[MANIFEST_REL], updates)
        merged[MANIFEST_REL] = manifest_bytes
        say(f"   已按 v{newver} 重算（{mode} 方式），共更新 {len(updates)} 条")
        for rel, data in merged.items():
            p = os.path.join(work, *rel.split("/"))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "wb") as fh:
                fh.write(data)
    else:
        git = shutil.which("git")
        if not git:
            warn("没找到 git，三方合并将使用粗暴退化模式（会误报大量冲突）")
        say("== 三方合并（base / ours / theirs）==")
        n_clean = n_auto = n_conf = 0
        for rel in merge_rels:
            ours = our_files[rel]
            theirs = new_files.get(rel)
            base = base_files.get(rel)
            if theirs is None:
                if base is None:      # 我们的新增文件（landscape.js）：官方本来就没有
                    merged[rel] = ours
                    conflicts[rel] = 0
                    n_clean += 1
                    say(f"   + {rel}")
                    continue
                warn(f"新版里没有 {rel}（官方似乎删掉了）—— 保留我们的版本")
                merged[rel] = ours
                conflicts[rel] = 0
                n_auto += 1
                continue
            data, c = merge3(rel, base if base is not None else b"", ours, theirs, git)
            merged[rel] = data
            conflicts[rel] = c
            if c == 0:
                n_clean += 1
            else:
                n_conf += 1
            flag = "  <- 冲突" if c else ""
            say(f"   {'~' if c else '='} {rel}{flag}")
        extra = f"（另有 {n_auto} 个官方已删除，保留我们的版本）" if n_auto else ""
        say(f"   合并完成：{n_clean} 个干净，{n_conf} 个有冲突{extra}")

        say("== 重算 MANIFEST.json ==")
        updates = {rel: (len(data), sha256_hex(data)) for rel, data in merged.items()}
        manifest_bytes, mode = build_manifest(new_files[MANIFEST_REL], updates)
        merged[MANIFEST_REL] = manifest_bytes
        say(f"   已按 v{newver} 重算（{mode} 方式），共更新 {len(updates)} 条")

        if os.path.isdir(work):
            shutil.rmtree(work)
        for rel, data in merged.items():
            p = os.path.join(work, *rel.split("/"))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "wb") as fh:
                fh.write(data)
        say(f"   合并结果已写到：{work}")

    # ---- 检查 ----
    conflicted = sorted(rel for rel, c in conflicts.items() if c)
    problems = []
    if not args.no_check:
        node = shutil.which("node")
        if not node:
            warn("没找到 node，跳过 JS 语法检查")
        for rel, data in merged.items():
            if rel.endswith(".js") and node:
                p = os.path.join(work, *rel.split("/"))
                if os.path.isfile(p):
                    r = subprocess.run([node, "--check", p], capture_output=True)
                    if r.returncode != 0:
                        problems.append(f"node --check {rel}:\n{r.stderr.decode('utf-8', 'replace').strip()}")
            elif rel.endswith(".json"):
                try:
                    json.loads(data.decode("utf-8"))
                except Exception as e:
                    problems.append(f"JSON 解析失败 {rel}: {e}")

    report = os.path.join(work, "_merge-report.txt")
    lines = [f"重建横屏补丁：官方 v{origin} → v{newver}", f"ours = {ours_path}",
             f"base = {base_path}", f"new  = {new_path}", "",
             f"合并文件 {len(merge_rels)} 个："]
    for rel in merge_rels:
        lines.append(f"  {'冲突' if conflicts.get(rel) else '  ok'}  {rel}")
    if problems:
        lines += ["", "检查问题："] + ["  " + p.replace("\n", "\n      ") for p in problems]
    if conflicted:
        lines += ["", "有冲突的文件（需要手工合并）："] + ["  " + r for r in conflicted]
        lines += ["", "改完这些文件后，用 --resolved 重跑本工具即可打包。"]
    os.makedirs(work, exist_ok=True)
    with open(report, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

    if conflicted or problems:
        say("")
        for ln in lines:
            say("   " + ln)
        if not args.force:
            say("")
            die(f"存在{'冲突' if conflicted else '检查问题'}，暂不打包。\n"
                f"    工作目录：{work}\n"
                f"    改好后：python {os.path.basename(__file__)} --ours \"{ours_path}\" --resolved"
                + (f" --new \"{new_path}\"" if args.new else ""))
        else:
            warn("(--force) 忽略以上问题，继续打包")

    # ---- 打包 ----
    say("== 写出升级包 ==")
    patch_out = os.path.join(out_dir, f"stronghold-v{newver}-landscape-patch.tar.gz")
    full_out = os.path.join(out_dir, f"stronghold-v{newver}-full-landscape.tar.gz")

    write_patch_bundle(patch_out, our_order, our_infos, merged)
    say(f"   增量补丁包：{patch_out}  ({os.path.getsize(patch_out) / 1024:.0f} KB)")

    appended = write_full_package(full_out, new_path, merged, our_order)
    say(f"   横屏完整包：{full_out}  ({os.path.getsize(full_out) / 1024 / 1024:.1f} MB)"
        + (f"，追加 {appended} 个新文件" if appended else ""))

    # ---- 复查 ----
    say("== 复查 ==")
    bad = []
    rb, _ = read_package(patch_out)
    for rel in our_order:
        if rb.get(rel) != merged[rel]:
            bad.append(f"补丁包 {rel} 与合并结果不一致")
    say(f"   增量补丁包：{len(rb)} 个文件，" + ("全部一致" if not bad else "有不一致!"))
    if not args.fast:
        rfull, rfull_infos = read_package(full_out, wanted=set(our_order))
        miss = [r for r in our_order if r not in rfull]
        for rel in our_order:
            if rel in rfull and rfull[rel] != merged[rel]:
                bad.append(f"完整包 {rel} 与合并结果不一致")
        if miss:
            bad.append("完整包缺少：" + ", ".join(miss))
        # 成员数：应等于新包成员数 + 追加数
        if new_path.lower().endswith(".zip"):
            with zipfile.ZipFile(new_path) as z:
                n_new = sum(1 for n in z.namelist() if not n.endswith("/"))
        else:
            with tarfile.open(new_path, "r:gz") as t:
                n_new = len(t.getmembers())
        with tarfile.open(full_out, "r:gz") as t:
            n_out = len(t.getmembers())
        expect = n_new + appended
        if n_out != expect:
            bad.append(f"完整包成员数 {n_out} != 预期 {expect}（新包 {n_new} + 追加 {appended}）")
        say(f"   横屏完整包：{n_out} 个成员（新包 {n_new} + 追加 {appended}），"
            + ("抽查 17 个文件一致" if not bad else "有问题!"))
    if bad:
        for b in bad:
            warn(b)
        if not args.force:
            die("复查失败（上面的包可能不可用，请勿部署）")

    # ---- 部署脚本 ----
    if not args.no_scripts:
        kit = os.path.dirname(os.path.abspath(__file__))
        src_dirs = [kit, os.path.join(kit, os.pardir, "deploy")]
        copied = []
        for name in ("deploy-landscape.sh", "deploy-landscape-patch.sh"):
            for d in src_dirs:
                src = os.path.join(d, name)
                if os.path.isfile(src):
                    shutil.copy2(src, os.path.join(out_dir, name))
                    copied.append(name)
                    break
        if copied:
            say(f"   已复制版本无关的部署脚本到输出目录：{', '.join(copied)}")
        else:
            warn("没找到 deploy-landscape*.sh 部署脚本（跳过复制）")

    # ---- 收尾 ----
    def sha(p):
        h = hashlib.sha256()
        with open(p, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()

    say("")
    say("=" * 68)
    say(f"完成：横屏 v{newver} 已重建")
    say(f"  补丁包  {patch_out}")
    say(f"          sha256 {sha(patch_out)}")
    say(f"  完整包  {full_out}")
    say(f"          sha256 {sha(full_out)}")
    say(f"  报告    {report}")
    say("")
    say("部署（上传到服务器 /www/wwwroot/ 后，root 执行）：")
    say("  增量：cd /www/wwwroot && bash deploy-landscape-patch.sh")
    say("  全量：cd /www/wwwroot && bash deploy-landscape.sh")
    say("=" * 68)


if __name__ == "__main__":
    main()
