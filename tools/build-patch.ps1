# 把 patch/ 打包成可部署的增量补丁包，并生成校验和。
#
#   pwsh tools/build-patch.ps1            → dist/stronghold-v<app>-landscape-patch.tar.gz
#                                            dist/SHA256SUMS.txt
#   pwsh tools/build-patch.ps1 -OutDir X  → 自定义输出目录
[CmdletBinding()]
param(
  [string]$OutDir = "dist"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$patchDir = Join-Path $root "patch"
if (-not (Test-Path (Join-Path $patchDir "MANIFEST.json"))) { throw "patch/MANIFEST.json 不存在，仓库不完整？" }

# 上游版本号从补丁自带的 MANIFEST.json 里读（"app":"0.3.0"）
$manifest = Get-Content (Join-Path $patchDir "MANIFEST.json") -Raw
if ($manifest -notmatch '"app"\s*:\s*"([^"]+)"') { throw "MANIFEST.json 里找不到 app 版本号" }
$app = $Matches[1]

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$outDirAbs = (Resolve-Path $OutDir).Path
$name = "stronghold-v$app-landscape-patch.tar.gz"
$out = Join-Path $outDirAbs $name

# tar 在 Windows 10/11 自带（bsdtar）。用 -C patch . 让小包内路径带 ./ 前缀，与原包一致。
if (Test-Path $out) { Remove-Item $out -Force }
& tar -czf $out -C $patchDir .
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) { throw "tar 打包失败" }

# 必须包含新增文件，否则部署脚本会拒绝
$members = & tar -tzf $out
if (-not ($members | Where-Object { $_ -match 'public/js/ui/landscape\.js$' })) {
  throw "产物里没有 public/js/ui/landscape.js，打包目录不对"
}
$count = ($members | Where-Object { $_ -notmatch '/$' }).Count

$hash = (Get-FileHash $out -Algorithm SHA256).Hash.ToLower()
$size = (Get-Item $out).Length
"$hash  $name" | Set-Content -Path (Join-Path $outDirAbs "SHA256SUMS.txt") -Encoding ascii

Write-Host ""
Write-Host "打包完成"
Write-Host "  上游版本 : $app"
Write-Host "  文件数   : $count"
Write-Host "  产物     : $out  ($([math]::Round($size/1KB,1)) KB)"
Write-Host "  sha256   : $hash"
Write-Host ""
Write-Host "上传到服务器后： bash deploy/deploy-landscape-patch.sh"
