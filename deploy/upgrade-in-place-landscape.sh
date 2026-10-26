#!/bin/bash
# =============================================================================
# 卫戍协议：盟约 · 一键横屏 · 原地升级到「任意版本 + 横屏」
#
#   和 deploy-landscape.sh 的区别：**不整体替换安装目录**，而是把完整横屏包覆盖解压
#   到现有安装目录，保留服主自己的 data/（服务器配置）、plugins/（插件）、packs/。
#
#   用法（root）：
#     1) 上传 stronghold-v*-full-landscape.tar.gz 到 /www/wwwroot/（约 800 MB）
#     2) cd /www/wwwroot && bash upgrade-in-place-landscape.sh
#        指定别的包：bash upgrade-in-place-landscape.sh --pkg /别的/路径.tar.gz
#
#   脚本会：检查 → 停服务 → 硬链接快照备份（秒级、几乎不占空间）→ 覆盖解压
#           （跳过 data/ plugins/ packs/）→ 权限 → 启动并验证 → 打印回滚命令
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
KEEP=(./data ./plugins ./packs)

say(){ printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn(){ printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die(){ printf '\n\033[1;31m[x] %s\033[0m\n' "$*"; exit 1; }
ver(){ grep -m1 '"version"' "$1" 2>/dev/null | tr -d ' ",' | cut -d: -f2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --pkg|-p) shift; PKG="${1:-}"; shift 2>/dev/null || true ;;
    --pkg=*) PKG="${1#*=}"; shift ;;
    --install|-i) shift; INSTALL="${1:-}"; shift 2>/dev/null || true ;;
    --install=*) INSTALL="${1#*=}"; shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) die "未知参数：$1（用法：bash $0 [--pkg 完整横屏包] [--install 安装目录]）" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "请用 root 运行"
[ -d "$INSTALL" ] || die "找不到安装目录 $INSTALL"
[ -f "$INSTALL/server/index.js" ] || die "$INSTALL 不像游戏安装目录（缺 server/index.js）"

if [ -z "$PKG" ]; then
  PKG=$(ls -1t "$BASE"/*full-landscape*.tar.gz /root/*full-landscape*.tar.gz "$(pwd)"/*full-landscape*.tar.gz 2>/dev/null | head -1)
fi
[ -n "$PKG" ] && [ -f "$PKG" ] || die "找不到完整横屏包（stronghold-v*-full-landscape.tar.gz）。上传到 $BASE/ 后重试，或用 --pkg 指定"

say "1/6 检查"
OLDVER=$(ver "$INSTALL/package.json"); OLDVER=${OLDVER:-未知}
NEWVER=$(tar -xzOf "$PKG" ./package.json 2>/dev/null | grep -m1 '"version"' | tr -d ' ",' | cut -d: -f2)
[ -n "$NEWVER" ] || die "读不出包内版本号（包可能不完整）：$PKG"
tar -tzf "$PKG" ./public/js/ui/landscape.js >/dev/null 2>&1 \
  || die "这不是横屏完整包（缺 public/js/ui/landscape.js）"
echo "  当前版本 : v$OLDVER"
echo "  升级包   : $PKG（$(du -h "$PKG" | cut -f1)）→ v$NEWVER + 横屏"
echo "  保留目录 : data/ plugins/ packs/（服主数据不覆盖）"
df -h "$BASE" | tail -1 | awk '{print "  磁盘可用 : "$4"（硬链接快照几乎不占空间；解压需要包体积的同级空间）"}'

say "2/6 停止服务 $SVC"
systemctl stop "$SVC" 2>/dev/null && echo "  已停止" || warn "服务未运行"

say "3/6 快照备份（硬链接，秒级）"
TS=$(date +%Y%m%d%H%M%S)
mkdir -p "$BACKUP_DIR"
BAK="$BACKUP_DIR/tree-v$OLDVER-$TS"
if ! cp -al "$INSTALL" "$BAK" 2>/dev/null; then
  warn "硬链接快照失败，改用普通复制（会慢一些）"
  rm -rf "$BAK"
  cp -a "$INSTALL" "$BAK" || { systemctl start "$SVC" >/dev/null 2>&1; die "备份失败，未做改动"; }
fi
echo "  已备份：$BAK"

say "4/6 覆盖解压（跳过 data/ plugins/ packs/）"
if ! tar -xzf "$PKG" -C "$INSTALL" \
      --exclude='./data' --exclude='./data/*' \
      --exclude='./plugins' --exclude='./plugins/*' \
      --exclude='./packs' --exclude='./packs/*'; then
  systemctl start "$SVC" >/dev/null 2>&1
  die "解压失败，安装目录可能不完整；服务已重启。回滚：rm -rf $INSTALL && mv $BAK $INSTALL && systemctl start $SVC"
fi
[ -f "$INSTALL/public/js/ui/landscape.js" ] || die "横屏文件未就位（缺 public/js/ui/landscape.js）"
grep -q 'sp-force-landscape' "$INSTALL/public/js/ui/landscape.js" || die "landscape.js 内容异常"
[ "$(ver "$INSTALL/package.json")" = "$NEWVER" ] || die "解压后版本号不是 v$NEWVER，请检查包"
echo "  已解压：v$NEWVER（data/ plugins/ packs/ 未改动）"

say "5/6 权限"
chown -R www:www "$INSTALL" 2>/dev/null || true
find "$INSTALL" -type d -exec chmod 755 {} \; 2>/dev/null
find "$INSTALL" -type f -exec chmod 644 {} \; 2>/dev/null

say "6/6 启动并验证"
systemctl daemon-reload 2>/dev/null || true
systemctl start "$SVC" || { journalctl -u "$SVC" -n 40 --no-pager | sed 's/^/  /'; die "启动失败，可用下面命令回滚"; }
OK=0
for _ in $(seq 1 45); do
  sleep 1
  H=$(curl -s --max-time 3 "http://127.0.0.1:$PORT/healthz" || true)
  case "$H" in *'"ok":true'*) OK=1; break ;; esac
done
if [ "$OK" != "1" ]; then
  warn "端口未就绪，真实原因："
  journalctl -u "$SVC" -n 50 --no-pager 2>/dev/null | sed 's/^/  /'
  echo
  echo "  一键回滚（复制执行）："
  echo "      systemctl stop $SVC"
  echo "      rm -rf $INSTALL && mv $BAK $INSTALL"
  echo "      systemctl start $SVC"
  die "升级后启动失败"
fi
echo "  ✅ /healthz → $H"
for u in / /js/main.js /js/ui/landscape.js /vendor/preact.module.js /data/config.json /studio/; do
  printf '  %-28s HTTP %s\n' "$u" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://127.0.0.1:$PORT$u")"
done
echo "  横屏适配 : $(curl -s --max-time 8 "http://127.0.0.1:$PORT/js/ui/landscape.js" | grep -q 'sp-force-landscape' && echo '已就位' || echo '⚠ 未检测到')"
echo "  实际版本 : v$(ver "$INSTALL/package.json")"
echo "  进程状态 : $(systemctl is-active $SVC)"

cat <<EOF

=============== 升级完成：v$OLDVER → v$NEWVER + 一键横屏 ===============
  浏览器验证：http://127.0.0.1:$PORT/（或你自己的域名）   ← 无痕窗口或 Ctrl+F5
  手机测试  ：竖屏打开 → 点「一键横屏」→ 画面旋转 90°；设置里可开「强制横屏」

  一键回滚（万一有问题）：
      systemctl stop $SVC && rm -rf $INSTALL && mv $BAK $INSTALL && systemctl start $SVC

  快照备份：$BAK
  日志    ：journalctl -u $SVC -f
=====================================================================
EOF
