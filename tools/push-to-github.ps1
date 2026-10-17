# 把本地仓库推到 GitHub（xyss415/stronghold-landscape）。
#
# 兼容 Windows 自带的 PowerShell 5.1 和 PowerShell 7：
#   powershell -NoProfile -File tools\push-to-github.ps1              # 直连
#   powershell -NoProfile -File tools\push-to-github.ps1 -Proxy 127.0.0.1:7890
#   powershell -NoProfile -File tools\push-to-github.ps1 -Force      # 远端已有提交时强推
#   powershell -NoProfile -File tools\push-to-github.ps1 -DryRun     # 只检查，不推送
#
# 认证：GitHub 只收 PAT（或 SSH key）。装了 Git Credential Manager 时首次 push 会弹窗登录；
# 也可以先设 $env:GH_TOKEN，脚本会把它拼进 URL（只在本次进程内，不写进 .git/config）。
[CmdletBinding()]
param(
  [string]$GitHubUser = "xyss415",
  [string]$Repo = "stronghold-landscape",
  [string]$Proxy = "",
  [string]$Token = $env:GH_TOKEN,
  [switch]$Force,
  [switch]$DryRun
)

# PS 5.1 在 $ErrorActionPreference='Stop' 时会把原生程序的 stderr 当成异常抛出，
# 而 git 的失败信息正好走 stderr，所以这里用 Continue，靠 $LASTEXITCODE 判断成败。
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
# 只有明确给了 token（或走 SSH）才禁用终端提示；否则保留提示，
# 让 Git Credential Manager / 终端能弹窗要凭证——否则会直接报 "could not read Username"。
if ($Token) { $env:GIT_TERMINAL_PROMPT = "0" }

function Say($m)  { Write-Host ""; Write-Host "==> $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

# 用 -C 指定仓库根目录：Set-Location 不会改变原生程序的工作目录，
# 这样不管从哪个目录调用脚本，git 都作用在正确的仓库上。
$git = @("git", "-C", $root)
if ($Proxy) { $git += @("-c", "http.proxy=http://$Proxy") }

function Run {
  param([string[]]$Cmd)
  $old = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    # 2>&1 把 git 的 stderr 收进输出流；逐条 [string] 化，避免 PS 5.1 打出
    # “git.exe : fatal: ... CategoryInfo/NativeCommandError” 那一大坨。
    $raw  = & $Cmd[0] @($Cmd[1..($Cmd.Length - 1)]) 2>&1
    $code = $LASTEXITCODE
    $out  = (@($raw | ForEach-Object { [string]$_ }) -join "`n").Trim()
  } finally {
    $ErrorActionPreference = $old
  }
  [pscustomobject]@{ Code = $code; Out = $out }
}

# ---- 1. 本地状态 ------------------------------------------------------------------
Say "1/4 检查本地仓库"
$r = Run ($git + @("rev-parse", "--abbrev-ref", "HEAD"))
if ($r.Code -ne 0) { Die "不是 git 仓库（或 git 不可用）：$root`n$($r.Out)" }
$branch = $r.Out
if ($branch -ne "main") { Warn "当前分支是 $branch，不是 main" }

$r = Run ($git + @("status", "--porcelain"))
if ($r.Out) { Warn "有未提交的改动（不影响推送，但新文件不会上去）" }

$r = Run ($git + @("log", "-1", "--format=%h %s"))
Write-Host "  提交   : $($r.Out)"
$r = Run ($git + @("log", "-1", "--format=%an <%ae>"))
Write-Host "  作者   : $($r.Out)"
$r = Run ($git + @("tag", "-l"))
if ($r.Out) { Write-Host "  标签   : $($r.Out -replace "`r?`n", ', ')" } else { Write-Host "  标签   : (无)" }

$url = "https://github.com/$GitHubUser/$Repo.git"
$r = Run ($git + @("remote", "get-url", "origin"))
if ($r.Code -ne 0 -or -not $r.Out) {
  Say "添加远程 origin → $url"
  if (-not $DryRun) { Run ($git + @("remote", "add", "origin", $url)) | Out-Null }
} else {
  $remote = $r.Out
  Write-Host "  远程   : origin → $remote"
  if ($remote -ne $url) { Warn "origin 与 $url 不一致；用 -GitHubUser/-Repo 指定，或先 git remote set-url origin $url" }
}

# ---- 2. 连通性 --------------------------------------------------------------------
Say "2/4 测试 GitHub 连通性（git ls-remote）"
$r = Run ($git + @("ls-remote", $url))
if ($r.Code -ne 0) {
  Write-Host "  $($r.Out)" -ForegroundColor DarkGray
  Warn "连不上 GitHub，推送中止。按下面提示处理后重试："
  Write-Host @"
  · SEC_E_NO_CREDENTIALS / SSL certificate  → schannel 或代理问题：
        git config --global http.sslBackend openssl
        powershell -File tools\push-to-github.ps1 -Proxy 127.0.0.1:7890
  · curl.exe https://github.com 返回 000    → 本机出不了网，换网络 / 开代理
  · 403 / Authentication failed             → PAT 无效，或没有 Contents: Read and write
  · Repository not found                    → 仓库名不对，或 PAT 没授权这个仓库
"@ -ForegroundColor Yellow
  exit 1
}
Write-Host "  可以连通 ✅"

if ($DryRun) {
  Say "DryRun：没推任何东西。去掉 -DryRun 就会推 $branch 和所有 tag。"
  exit 0
}

# ---- 3. 推送分支 ------------------------------------------------------------------
$pushUrl = $url
if ($Token) {
  # 只在本次进程内使用，不写进 .git/config
  $pushUrl = "https://$GitHubUser`:$Token@github.com/$GitHubUser/$Repo.git"
}

$pushArgs = @("push")
if ($Force) { $pushArgs += "--force" }
$pushArgs += @($pushUrl, "refs/heads/$branch:refs/heads/$branch")

$mode = ""
if ($Force) { $mode = "（强推）" }
Say "3/4 推送分支 $branch$mode"
if (-not $Token) {
  Write-Host "  需要认证时会弹窗 / 提示输入：用户名 $GitHubUser，密码位置粘 PAT（个人访问令牌）" -ForegroundColor DarkGray
}

$r = Run ($git + $pushArgs)
if ($r.Code -ne 0) {
  Write-Host ""
  Write-Host "-------------- git 的原始报错（把这一段贴出来最快） --------------" -ForegroundColor Red
  Write-Host $r.Out
  Write-Host "-----------------------------------------------------------------" -ForegroundColor Red
  $log = Join-Path $root "push-error.log"
  $r.Out | Set-Content -LiteralPath $log -Encoding UTF8
  Write-Host "  已存到 $log" -ForegroundColor DarkGray
  Write-Host ""

  $o = $r.Out
  if ($o -match 'could not read Username|terminal prompts disabled|Authentication failed|Invalid username or password|403|Permission to .+ denied') {
    Warn "认证问题：git 拿不到可用凭证（最常见）。"
    Write-Host @"
  任选一种：
   1) 允许弹窗登录（最省事）：
        git -C $root push -u origin $branch
      Git Credential Manager 会开浏览器；若提示输入，用户名 $GitHubUser，密码处粘 PAT。
   2) 把 PAT 交给脚本（只在本次进程内使用，不写进 .git/config）：
        `$env:GH_TOKEN = "ghp_你的令牌"
        powershell -NoProfile -File tools\push-to-github.ps1
      PAT：https://github.com/settings/tokens → Fine-grained → Repository access 选 $Repo
           → Permissions → Contents: Read and write。
"@ -ForegroundColor Yellow
  } elseif ($o -match '\[rejected\]|non-fast-forward|fetch first|Updates were rejected') {
    Warn "远端已经有本地没有的提交（建仓库时勾了 README / .gitignore / license）。"
    Write-Host @"
  任选一种：
   1) 强推，用本地这版覆盖远端（新仓库没有别人的提交，安全）：
        powershell -NoProfile -File tools\push-to-github.ps1 -Force
   2) 保留远端那个 README，把本地提交接在后面：
        git -C $root pull --rebase origin $branch
        git -C $root push -u origin $branch
"@ -ForegroundColor Yellow
  } elseif ($o -match 'Repository not found|does not exist|not found') {
    Warn "仓库不存在或没有权限：确认 https://github.com/$GitHubUser/$Repo 能打开，且 PAT 授权了这个仓库。"
  } elseif ($o -match 'SSL|certificate|schannel|SEC_E|Could not resolve host|Failed to connect|Connection was reset|timed out') {
    Warn "网络层问题：换网络或开代理后重试，例如 -Proxy 127.0.0.1:7890。"
  } else {
    Warn "没识别出原因，把上面红色区间的报错贴出来。"
  }
  Die "推送分支失败"
}

# ---- 4. 推送标签（触发 Actions 建 Release） ---------------------------------------
$r = Run ($git + @("tag", "-l"))
$tags = @($r.Out -split "`r?`n" | Where-Object { $_ })
if ($tags.Count -gt 0) {
  Say "4/4 推送标签：$($tags -join ', ')"
  $r = Run ($git + @("push", $pushUrl, "--tags"))
  if ($r.Code -ne 0) {
    Write-Host $r.Out -ForegroundColor Red
    Warn "标签推送失败；修好认证后重试：git -C $root push origin --tags（或加 -Force）"
  }
} else {
  Say "4/4 没有标签需要推送（没有 tag 就不会自动建 Release）"
}

Write-Host @"

=============== 推送完成 ===============
  仓库    ：https://github.com/$GitHubUser/$Repo
  代码    ：https://github.com/$GitHubUser/$Repo/tree/$branch
  Actions ：https://github.com/$GitHubUser/$Repo/actions      ← tag 触发打包
  Release ：https://github.com/$GitHubUser/$Repo/releases

  接下来：
   1. Actions 变绿后，Release 里应出现
      stronghold-v0.3.0-landscape-patch.tar.gz 和 SHA256SUMS.txt
   2. 验证下载：
      curl.exe -L -o patch.tar.gz https://github.com/$GitHubUser/$Repo/releases/latest/download/stronghold-v0.3.0-landscape-patch.tar.gz
   3. 右侧 About 填描述；Topics 建议
      stronghold-protocol arknights landscape patch gplv3
========================================
"@ -ForegroundColor Cyan
