#!/bin/bash
# =============================================================================
# 卫戍协议：盟约 · 一键横屏 · 增量更新部署（版本无关，可长期复用）
#
#   前提：安装目录里已经是「补丁包对应的那一版官方完整包」——脚本自己从补丁包的
#         MANIFEST.json 里读出所需版本并核对，不符就中止（不会乱改安装目录）。
#   补丁包只含 16 个替换文件 + 1 个新增文件（约 760 KB）：
#     不需要上传完整包、不动 node_modules / public/assets、不用 npm ci、不用联网。
#
#   用法（root）：
#     1) 上传 stronghold-v*-landscape-patch.tar.gz 到 /www/wwwroot/
#     2) cd /www/wwwroot && bash deploy-landscape-patch.sh
#
#   脚本会：检查前提 → 备份当前代码（几百KB）→ 停服务 → 覆盖解压 → 权限
#           → 启动并验证 /healthz 与 landscape.js → 打印一键回滚命令
#
#   ⚠️ 会结束正在进行中的对局（游戏无存档）——请在没人玩时执行
# =============================================================================
set -uo pipefail

BASE=/www/wwwroot
INSTALL="$BASE/game-stronghold"
PKG=""
SVC=stronghold
PORT=3001
[ -f /etc/default/$SVC ] && PORT=$(grep -oP '^PORT=\K.*' /etc/default/$SVC 2>/dev/null || echo 3001)
BACKUP_DIR=/www/backup/stronghold-code

say(){ printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn(){ printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die(){ printf '\n\033[1;31m[x] %s\033[0m\n' "$*"; exit 1; }
ver(){ grep -m1 '"version"' "$1" 2>/dev/null | tr -d ' ",' | cut -d: -f2; }

# 可选参数：--pkg <补丁包>，--install <安装目录>，-h/--help
while [ $# -gt 0 ]; do
  case "$1" in
    --pkg|-p) shift; PKG="${1:-}"; shift 2>/dev/null || true ;;
    --pkg=*) PKG="${1#*=}"; shift ;;
    --install|-i) shift; INSTALL="${1:-}"; shift 2>/dev/null || true ;;
    --install=*) INSTALL="${1#*=}"; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) die "未知参数：$1（用法：bash $0 [--pkg 补丁包] [--install 安装目录]）" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "请用 root 运行"
[ -d "$INSTALL" ] || die "找不到安装目录 $INSTALL（全新安装请用一键部署 deploy-v030-landscape.sh）"
[ -f "$INSTALL/server/index.js" ] || die "$INSTALL 不像游戏安装目录（缺 server/index.js）"
if [ -n "$PKG" ] && [ ! -f "$PKG" ]; then
  warn "找不到 $PKG，尝试自动搜索别处…"
  PKG=""
fi
if [ -z "$PKG" ]; then
  for c in "$(ls -1t "$BASE"/*landscape*patch*.tar.gz /root/*landscape*patch*.tar.gz "$(pwd)"/*landscape*patch*.tar.gz 2>/dev/null | head -1)" \
           "$(find /www /root -maxdepth 4 -name '*landscape*patch*.tar.gz' -type f 2>/dev/null | head -1)"; do
    [ -n "$c" ] && [ -f "$c" ] && { PKG="$c"; break; }
  done
fi
[ -n "$PKG" ] && [ -f "$PKG" ] || die "找不到横屏增量补丁包（stronghold-v*-landscape-patch.tar.gz）。上传到 $BASE/ 后重试，或用 --pkg 指定"

# 读取补丁清单（去掉前导 ./）
MEMBERS=()
while IFS= read -r line; do [ -n "$line" ] && MEMBERS+=("$line"); done < <(tar -tzf "$PKG" | sed 's#^\./##' | grep -v '/$')
[ "${#MEMBERS[@]}" -gt 0 ] || die "补丁包为空或损坏：$PKG"
case " ${MEMBERS[*]} " in
  *" public/js/ui/landscape.js "*) : ;;
  *) die "补丁包内容不对（缺 public/js/ui/landscape.js），请确认上传的是 *-landscape-patch.tar.gz" ;;
esac

# 从补丁包自带的 MANIFEST.json 读出这一版补丁适用于哪个官方版本
NEED=$(tar -xzOf "$PKG" ./MANIFEST.json 2>/dev/null | head -1 | sed -n 's/.*"app":"\([^"]*\)".*/\1/p')
[ -n "$NEED" ] || NEED=$(tar -xzOf "$PKG" MANIFEST.json 2>/dev/null | head -1 | sed -n 's/.*"app":"\([^"]*\)".*/\1/p')
[ -n "$NEED" ] || die "无法从补丁包的 MANIFEST.json 读出所需版本，包可能损坏：$PKG"

say "1/6 检查升级前提"
CUR=$(ver "$INSTALL/package.json"); CUR=${CUR:-未知}
echo "  当前安装 : v$CUR"
echo "  补丁包   : $PKG（$(du -h "$PKG" | cut -f1)，共 ${#MEMBERS[@]} 个文件）"
echo "  补丁适用 : v$NEED"
if [ "$CUR" != "$NEED" ]; then
  warn "当前是 v$CUR，但这个补丁是针对 v$NEED 的（覆盖 public/js·css·i18n 等）。
  请先把安装目录恢复/安装到官方 v$NEED 完整包，再执行本脚本。"
  die "版本不匹配，已中止（安装目录未被改动）"
fi
echo "  版本匹配 ✅（v$NEED）"

say "2/6 备份当前 v$CUR 代码（几百 KB）"
TS=$(date +%Y%m%d%H%M%S)
mkdir -p "$BACKUP_DIR"
BAK="$BACKUP_DIR/code-v$CUR-before-landscape-$TS.tar.gz"
tar -czf "$BAK" -C "$INSTALL" MANIFEST.json docs public/index.html public/js public/css public/i18n 2>/dev/null || true
[ -s "$BAK" ] || die "备份失败（$BAK），未做改动"
echo "  已备份：$BAK（$(du -h "$BAK" | cut -f1)）"

say "3/6 停止服务 $SVC"
systemctl stop "$SVC" 2>/dev/null && echo "  已停止" || warn "服务未运行"

say "4/6 覆盖解压补丁（只覆盖同名文件，不删除其它文件）"
if ! tar -xzf "$PKG" -C "$INSTALL"; then
  systemctl start "$SVC" >/dev/null 2>&1
  die "解压失败，安装目录可能不完整；服务已重新启动"
fi
[ -f "$INSTALL/public/js/ui/landscape.js" ] || die "补丁未就位（缺 public/js/ui/landscape.js）"
grep -q 'sp-force-landscape' "$INSTALL/public/js/ui/landscape.js" || die "landscape.js 内容异常，请重新上传补丁包"
echo "  已覆盖 ${#MEMBERS[@]} 个文件，landscape.js 就位"

say "5/6 权限"
chown -R www:www "$INSTALL" 2>/dev/null || true
find "$INSTALL" -type d -exec chmod 755 {} \; 2>/dev/null
find "$INSTALL" -type f -exec chmod 644 {} \; 2>/dev/null

say "6/6 启动并验证"
systemctl daemon-reload 2>/dev/null || true
systemctl start "$SVC" || { journalctl -u "$SVC" -n 40 --no-pager | sed 's/^/  /'; die "启动失败，可用下面命令回滚"; }
OK=0
for i in $(seq 1 45); do
  sleep 1
  H=$(curl -s --max-time 3 "http://127.0.0.1:$PORT/healthz" || true)
  case "$H" in *'"ok":true'*) OK=1; break ;; esac
done
if [ "$OK" != "1" ]; then
  warn "端口未就绪，真实原因："
  echo "  ---- journalctl -u $SVC（末 50 行）----"; journalctl -u "$SVC" -n 50 --no-pager 2>/dev/null | sed 's/^/  /'
  echo "  ---- $SVC-error.log ----"; tail -30 "/www/wwwlogs/$SVC-error.log" 2>/dev/null | sed 's/^/  /'
  echo
  echo "  一键回滚（复制执行）："
  echo "      systemctl stop $SVC"
  echo "      tar -xzf $BAK -C $INSTALL"
  echo "      rm -f $INSTALL/public/js/ui/landscape.js"
  echo "      systemctl start $SVC"
  die "横屏增量更新后启动失败"
fi
echo "  ✅ /healthz → $H"
for u in / /js/main.js /js/ui/landscape.js /vendor/preact.module.js /data/config.json /studio/; do
  printf '  %-28s HTTP %s\n' "$u" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://127.0.0.1:$PORT$u")"
done
echo "  横屏适配 : $(curl -s --max-time 8 "http://127.0.0.1:$PORT/js/ui/landscape.js" | grep -q 'sp-force-landscape' && echo '已就位（landscape.js 内容正确）' || echo '⚠ 未检测到')"
echo "  实际版本 : v$(ver "$INSTALL/package.json")"
echo "  进程状态 : $(systemctl is-active $SVC)（开机自启：$(systemctl is-enabled $SVC 2>/dev/null)）"
echo "  ---- MANIFEST 自检 ----"
NODE_BIN=$(command -v node || echo /www/server/nodejs/v24.21.0/bin/node)
[ -f "$INSTALL/tools/doctor.mjs" ] && "$NODE_BIN" "$INSTALL/tools/doctor.mjs" 2>&1 | sed 's/^/  /' | head -20 || echo "  (无 doctor.mjs，跳过)"

cat <<EOF

=============== v$CUR 横屏适配版 · 增量更新完成 ===============
  浏览器验证：http://127.0.0.1:$PORT/（或你自己的域名）   ← 无痕窗口或 Ctrl+F5（旧缓存会显示老界面）
  版本确认  ：curl -s http://127.0.0.1:$PORT/healthz

  手机测试  ：竖屏打开 → 出现「请将设备横屏」时点「一键横屏」，
              画面立刻转 90°（不能自动转屏的浏览器也能玩）。
              对局里 HUD 角落、标题画面也有旋转按钮；设置里有「强制横屏」开关。

  一键回滚（万一有问题）：
      systemctl stop $SVC && tar -xzf $BAK -C $INSTALL && rm -f $INSTALL/public/js/ui/landscape.js && systemctl start $SVC

  备份文件：$BAK
  日志    ：journalctl -u $SVC -f

  本补丁相对官方 v$NEED 的改动（不影响联机，只覆盖 ${#MEMBERS[@]} 个文件）：
   · 新增 public/js/ui/landscape.js：一键横屏（转画面，不依赖系统转屏）
   · 提示层新增「一键横屏 / 全屏」按钮；设置里有「强制横屏」开关
   · 对局 HUD 角与标题画面也有旋转按钮；设备真横过来时自动恢复
============================================================
EOF
