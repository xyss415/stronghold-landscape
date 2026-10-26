# 发布到 GitHub（照着做一遍就行）

仓库已经在 `F:\dsharness\stronghold-landscape` 准备好了：源码、README、LICENSE、NOTICE、
打包脚本、GitHub Actions 都在里面。下面 7 步做完，别人就能在 GitHub 上看到并下载这个插件。

> 本机 `git config --global user.name/user.email` 是空的，但仓库里已经配好**仓库级**身份
> （`Stronghold-Protocol La-Op` / `xyss415@users.noreply.github.com`），所以不用动全局配置。
> 唯一还没通过的是网络：这台机器连 GitHub 的 SSL 握手失败（代理没开），第 3 步推送前先解决。

## 0. 占位符与敏感信息（已完成）

文档里的 `YOUR_GITHUB_USER` 已全部替换成 `xyss415`；部署脚本里的服务器域名已改成
`127.0.0.1` / 「你自己的域名」的通用说法。以后换用户名或再抄一份仓库时照下面做：

```powershell
cd F:\dsharness\stronghold-landscape
$me = "xyss415"
Get-ChildItem -Recurse -File -Include *.md,*.yml | ForEach-Object {
  (Get-Content $_.FullName -Raw).Replace("YOUR_GITHUB_USER", $me) | Set-Content $_.FullName -NoNewline
}
Select-String -Path (Get-ChildItem -Recurse -File -Include *.md,*.yml).FullName -Pattern "YOUR_GITHUB_USER"   # 应当没有输出
```

顺手确认没把不该公开的东西带出去（脚本里只有 `127.0.0.1`、`/www/wwwroot` 这类通用路径）：

```powershell
Select-String -Path (Get-ChildItem -Recurse -File -Include *.sh,*.js,*.md).FullName `
  -Pattern 'root@|PRIVATE KEY|password|passwd|api[_-]?key|[0-9]{1,3}(\.[0-9]{1,3}){3}'
```

## 1. 在 GitHub 上建仓库

网页方式（推荐）：

1. 打开 <https://github.com/new>
2. **Repository name**：`stronghold-landscape`
3. **Description**：`卫戍协议：盟约 v0.3.3 一键横屏补丁 —— 转画面，不转设备`
4. 选 **Public**（私有仓库别人下不了 Release，插件就没意义了）
5. **不要**勾 "Add a README / .gitignore / license"——本地已经有了，勾了会导致首次 push 冲突
6. Create repository

命令方式（装了 GitHub CLI 时）：`gh repo create stronghold-landscape --public --source . --push`

## 2. 本地初始化并提交（已完成）

仓库已经 `git init` + 提交过了，身份用的是仓库级配置：

```powershell
cd F:\dsharness\stronghold-landscape
git config user.name  "Stronghold-Protocol La-Op"
git config user.email "xyss415@users.noreply.github.com"
git log --oneline
```

> 想让提交邮箱带上你的数字 ID（形如 `415+xyss415@users.noreply.github.com`），
> 去 <https://github.com/settings/emails> 复制 GitHub 给出的 noreply 地址，然后
> `git config user.email "..."` + `git commit --amend --reset-author --no-edit`。

如果想推倒重来：`rm -rf .git && git init -b main && git add -A && git commit -m "..."`。

## 3. 关联远程并推送

> origin 已经配好（`https://github.com/xyss415/stronghold-landscape.git`），本地提交 + tag `v0.3.3-ls1`。
> 最省事的方式：在有 GitHub 网络的机器上跑 `powershell -NoProfile -File tools\push-to-github.ps1`
> ——它会自检状态、测连通性、推 `main` 和所有 tag，失败时直接给出对应处理办法。
> 走代理加 `-Proxy 127.0.0.1:7890`，只想检查加 `-DryRun`。
> （Windows 自带的是 `powershell` 5.1；`pwsh` 是 PowerShell 7，需要另外安装，没装就用前者。）

手工方式（GitHub 只收 **PAT** 或 SSH key，不收账号密码；PAT 在
<https://github.com/settings/tokens> 建，Fine-grained 并只授权这个仓库的 `Contents: Read and write`）：

```powershell
git remote add origin https://github.com/xyss415/stronghold-landscape.git
git push -u origin main            # 用户名 xyss415，密码处粘 PAT
git push origin v0.3.3-ls1        # 触发 Actions → 自动建 Release
```

想用 SSH 而不是 PAT：

```powershell
ssh-keygen -t ed25519 -C "xyss415@users.noreply.github.com"
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub | Set-Clipboard   # 粘到 GitHub → Settings → SSH keys
git remote set-url origin git@github.com:xyss415/stronghold-landscape.git
git push -u origin main
```

这台开发机目前连不上 GitHub（`schannel: SEC_E_NO_CREDENTIALS`、`curl https://github.com` 返回 000，
本机也没有在监听的代理端口），所以推送要在你自己那边的网络执行；或者先在能上网的机器上
`git clone` 本地的 bundle 再推：

```powershell
git bundle create ..\stronghold-landscape.bundle --all
# 拷到另一台机器：
git clone stronghold-landscape.bundle repo && cd repo && git remote set-url origin https://github.com/xyss415/stronghold-landscape.git
git push origin main --tags
```

## 4. 发 Release（补丁包不要进 git）

仓库里只放源码；`dist/*.tar.gz` 走 Release 资产（单个资产上限 2 GB，仓库文件上限 100 MB）。

**方式 A：打 tag，Actions 自动打包发布**

```powershell
git tag -a v0.3.3-ls1 -m "landscape patch for upstream 0.3.3"
git push origin v0.3.3-ls1
```

`.github/workflows/release.yml` 会 `bash tools/build-patch.sh` 打包、校验包里含
`public/js/ui/landscape.js`，然后 `gh release create` 把 `dist/*.tar.gz` 和 `SHA256SUMS.txt` 挂上去。

**方式 B：本地打包 + 网页上传**

```powershell
powershell -NoProfile -File tools\build-patch.ps1
# → dist/stronghold-v0.3.3-landscape-patch.tar.gz + SHA256SUMS.txt
```

GitHub → Releases → *Draft a new release* → tag `v0.3.3-ls1` → 标题「横屏补丁 v0.3.3-ls1」
→ 说明直接粘 `CHANGELOG.md` → 上传两个文件 → Publish。

**方式 C：gh CLI**

```powershell
winget install --id GitHub.cli -e
gh auth login
gh release create v0.3.3-ls1 (Get-ChildItem dist\*.tar.gz).FullName dist\SHA256SUMS.txt `
  --title "横屏补丁 v0.3.3-ls1" --notes-file CHANGELOG.md
```

可选：把横屏**完整包**（`stronghold-v0.3.3-full-landscape.tar.gz`，约 800 MB）也挂到同一个
Release 里，玩家不想打补丁就能直接装。它永远不进 git。

## 5. 补全仓库信息

- 右侧 **About** ⚙：粘贴描述；Website 可填游戏地址或空；**Topics** 建议
  `stronghold-protocol` `arknights` `landscape` `mobile` `patch` `gplv3` `webgame`
- **Releases**：把 v0.3.3-ls1 勾成 *Latest*
- **Settings → General → Features**：Issues 打开（收兼容性反馈），Discussions 可选
- 确认 LICENSE 页显示 **GPL-3.0**；README 顶部徽章里的链接点一遍
- 可选：Settings → Pages 用 `docs/` 起个静态页放效果截图

## 6. 别提交的东西

| 别提交 | 原因 |
|---|---|
| `stronghold-v0.3.3-full*.tar.gz`（800–830 MB） | 单文件 >100 MB 直接被 GitHub 拒收；进过历史还得 `git filter-repo` 清 |
| `node_modules/`、`public/assets/` | 上游素材，且体积大；补丁用不到 |
| 服务器 IP / 域名 / 面板地址 / SSH 私钥 | 泄露后很难收回。脚本里已改成 `127.0.0.1` 和相对路径 |
| 备份 tar（`/www/backup/...`） | 里面是别人服务器的代码快照 |

`.gitignore` 已经挡掉 `dist/`、`*.tar.gz`、`node_modules/`、`__pycache__/` 等。

## 7. 常见问题

| 现象 | 处理 |
|---|---|
| `pwsh : 无法将“pwsh”项识别为 cmdlet...` | `pwsh` 是 PowerShell 7，Windows 自带的是 `powershell` 5.1。改用 `powershell -NoProfile -File tools\push-to-github.ps1`（脚本已按 5.1 兼容，UTF-8 BOM 也加了） |
| `SSL connection could not be established` / `OpenSSL SSL_connect` | 网络或代理问题。开代理后：`git config --global http.proxy http://127.0.0.1:7890`（HTTPS_PROXY 同理） |
| 推送要求输入密码 | GitHub 只收 PAT 或 SSH key，不收账号密码（用户名填 `xyss415`，密码处粘 PAT） |
| `could not read Username for 'https://github.com': terminal prompts disabled` / `Authentication failed for ...` / `403` | 脚本拿不到凭证。**交互式**跑一次让凭据管理器弹窗：`git -C F:\dsharness\stronghold-landscape push -u origin main`；或 `$env:GH_TOKEN="ghp_..."` 后重跑脚本（旧版脚本会强制关掉终端提示，已修正） |
| `! [rejected] main -> main (fetch first)` / `non-fast-forward` | 远端已有提交（建仓库时勾了 README）。用 `-Force` 覆盖：`powershell -NoProfile -File tools\push-to-github.ps1 -Force`；或保留远端：`git pull --rebase origin main` 再推 |
| `remote: error: File ... is 123.00 MB; exceeds GitHub's file size limit of 100.00 MB` | 大文件别进 git，挂 Release |
| `Updates were rejected because the remote contains work...` | 建仓库时勾了 README。`git pull --rebase origin main` 再推，或者删掉远程仓库重建 |
| 提交作者是错的 | `git config user.email ...` 后 `git commit --amend --reset-author` |
| 想改仓库名/改成私有 | Settings → General → Rename。私有化后 Release 下载链接会失效，别忘了改 README |

## 8. 另一种选择：直接并进上游

如果 `sganggs/Stronghold-Protocol` 也是你的仓库，那更省事的做法是把这个改动做成上游的一个分支，
或者干脆在上游内置「强制横屏」开关，而不是长期维护一个和版本严格绑定的补丁包
（补丁里的 `MANIFEST.json` 记着 v0.3.3 每个文件的 sha256，上游一升级补丁就失效，得用
`tools/rebuild-landscape.py` 重新定基）。

顺便说明为什么不打包成 0.3.3 的插件系统（`plugins/*/plugin.json`）：插件系统的 UI 插件只能操作 DOM，
够不到渲染层的坐标换算，而横屏需要阴影 `getBoundingClientRect` / `elementFromPoint` /
`innerWidth` 这些原型，只能改本体文件。
