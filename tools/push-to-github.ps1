# 把本地仓库推到 GitHub（xyss415/stronghold-landscape）。
#
#   pwsh tools/push-to-github.ps1                     # 直连推送
#   pwsh tools/push-to-github.ps1 -Proxy 127.0.0.1:7890   # 走本地代理
#   pwsh tools/push-to-github.ps1 -DryRun             # 只检查状态，不推送
#
# 认证：GitHub 只收 PAT（或 SSH key）。开启 Git Credential Manager 后首次 push 会弹网页登录，
# 也可以先设环境变量 $env:GH_TOKEN，脚本会拼进 URL（不落盘，仅本次进程）。
[CmdletBinding()]
param(
  [string]$GitHubUser = "xyss415",
  [string]$Repo = "stronghold-landscape",
  [string]$Proxy = "",
  [string]$Token = $env:GH_TOKEN,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Say($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die($m) { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

$env:GIT_TERMINAL_PROMPT = "0"
$gitArgs = @()
if ($Proxy) { $gitArgs = @("-c", "http.proxy=http://$Proxy") }

# ---- 1. 本地状态 ------------------------------------------------------------------
Say "1/4 检查本地仓库"
if (-not (Test-Path ".git")) { Die "当前目录不是 git 仓库：$root" }
$branch = (git rev-parse --abbrev-ref HEAD).Trim()
if ($branch -ne "main") { Warn "当前分支是 $branch，不是 main" }
if ((git status --porcelain)) { Warn "有未提交的改动（不影响推送，但新文件不会上去）" }
$commit = (git log -1 --format="%h %s").Trim()
Write-Host "  提交   : $commit"
Write-Host "  作者   : $((git log -1 --format='%an <%ae>').Trim())"
$tags = @(git tag -l)
Write-Host "  标签   : $(if ($tags.Count) { $tags -join ', ' } else { '(无)' })"

$url = "https://github.com/$GitHubUser/$Repo.git"
$remote = ""
try { $remote = (git remote get-url origin).Trim() } catch { }
if (-not $remote) {
  Say "添加远程 origin → $url"
  if (-not $DryRun) { git remote add origin $url }
} elseif ($remote -match 'github\.com[:/](?<u>[^/]+)/(?<r>[^/.]+)') {
  if ($Matches.u -ne $GitHubUser -or $Matches.r -ne $Repo) {
    Warn "origin 现在指向 $remote，与 $url 不一致；用 -GitHubUser/-Repo 指定或先 git remote set-url"
  } else {
    Write-Host "  远程   : origin → $remote"
  }
}

# ---- 2. 连通性 --------------------------------------------------------------------
Say "2/4 测试 GitHub 连通性（git ls-remote）"
$probe = & git @gitArgs ls-remote $url 2>&1
if ($LASTEXITCODE -ne 0) {
  $err = ($probe | Out-String)
  Write-Host $err.Trim() -ForegroundColor DarkGray
  Warn "连不上 GitHub，推送中止。按下面提示处理后重试："
  Write-Host @"
  · SEC_E_NO_CREDENTIALS / OpenSSL verify result   → schannel 或代理问题：
        git config --global http.sslBackend openssl
        pwsh tools/push-to-github.ps1 -Proxy 127.0.0.1:7890
  · curl https://github.com 返回 000              → 本机出不了网，换网络 / 开代理
  · 403 / Authentication failed                   → PAT 无效或没有 Contents: Read and write
  · Repository not found                          → 仓库名拼错，或 PAT 没授权这个仓库
"@ -ForegroundColor Yellow
  exit 1
}
Write-Host "  可以连通 ✅"

if ($DryRun) { Say "DryRun：不推送。去掉 -DryRun 即可推 main 与所有 tag。"; exit 0 }

# ---- 3. 推送 ----------------------------------------------------------------------
$pushUrl = $url
if ($Token) {
  # 只在本进程内使用，不写进 .git/config
  $pushUrl = "https://$GitHubUser`:$Token@github.com/$GitHubUser/$Repo.git"
  $gitArgs = @()
}

Say "3/4 推送 $branch"
& git @gitArgs push $pushUrl "refs/heads/${branch}:refs/heads/${branch}"
if ($LASTEXITCODE -ne 0) { Die "推送分支失败（上面有 git 的报错）" }

if ($tags.Count -gt 0) {
  Say "4/4 推送标签 $($tags -join ', ')"
  & git @gitArgs push $pushUrl --tags
  if ($LASTEXITCODE -ne 0) { Warn "标签推送失败；可稍后重试 git push origin --tags" }
} else {
  Say "4/4 没有标签需要推送"
}

Write-Host @"

=============== 推送完成 ===============
  仓库    ：https://github.com/$GitHubUser/$Repo
  代码    ：https://github.com/$GitHubUser/$Repo/tree/$branch
  Actions ：https://github.com/$GitHubUser/$Repo/actions      ← 打 tag 后这里会自动打包
  Release ：https://github.com/$GitHubUser/$Repo/releases

  接下来：
   1. 看 Actions 有没有变绿；变绿后 Release 里应出现
      stronghold-v0.3.0-landscape-patch.tar.gz 与 SHA256SUMS.txt
   2. 验证下载地址能下到包：
      curl -L -o patch.tar.gz https://github.com/$GitHubUser/$Repo/releases/latest/download/stronghold-v0.3.0-landscape-patch.tar.gz
   3. 右侧 About 填描述 + Topics（stronghold-protocol arknights landscape patch gplv3）
========================================
"@ -ForegroundColor Cyan
