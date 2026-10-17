#!/usr/bin/env bash
# 把 patch/ 打包成可部署的增量补丁包（Linux / macOS / CI 用）。
#
#   bash tools/build-patch.sh              → dist/stronghold-v<app>-landscape-patch.tar.gz
#   OUT=/tmp/out bash tools/build-patch.sh → 自定义输出目录
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${OUT:-dist}"
PATCH_DIR="patch"

[ -f "$PATCH_DIR/MANIFEST.json" ] || { echo "[x] patch/MANIFEST.json 不存在，仓库不完整？" >&2; exit 1; }

APP=$(sed -n 's/.*"app"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PATCH_DIR/MANIFEST.json" | head -1)
[ -n "${APP:-}" ] || { echo "[x] MANIFEST.json 里找不到 app 版本号" >&2; exit 1; }

mkdir -p "$OUT"
NAME="stronghold-v${APP}-landscape-patch.tar.gz"
# -C patch . → 包内路径带 ./ 前缀，和原始补丁包一致
tar -czf "$OUT/$NAME" -C "$PATCH_DIR" .

tar -tzf "$OUT/$NAME" | grep -q 'public/js/ui/landscape\.js$' \
  || { echo "[x] 产物里没有 public/js/ui/landscape.js，打包目录不对" >&2; exit 1; }

COUNT=$(tar -tzf "$OUT/$NAME" | grep -vc '/$' || true)
( cd "$OUT" && sha256sum "$NAME" > SHA256SUMS.txt )

echo
echo "打包完成"
echo "  上游版本 : $APP"
echo "  文件数   : $COUNT"
echo "  产物     : $OUT/$NAME ($(du -h "$OUT/$NAME" | cut -f1))"
echo "  sha256   : $(cut -d' ' -f1 "$OUT/SHA256SUMS.txt")"
echo
echo "上传到服务器后： bash deploy/deploy-landscape-patch.sh"
