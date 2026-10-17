# 卫戍协议：盟约 · 一键横屏补丁

![app](https://img.shields.io/badge/app-0.3.0-2ea44f)
![patch](https://img.shields.io/badge/patch-v0.3.0--ls1-blue)
![license](https://img.shields.io/badge/code%20license-GPL--3.0--or--later-blue)
![size](https://img.shields.io/badge/patch-17%20files%20~640%20KB-informational)

[卫戍协议：盟约 / Stronghold Protocol: Alliance](https://github.com/sganggs/Stronghold-Protocol) 的**横屏适配补丁**。

游戏是按横屏设计的，竖着拿手机时只弹一句「请将设备横屏」。可 iPhone Safari、微信 / QQ / 各类 App 内置
WebView 既不会自动转屏，也不允许 `screen.orientation.lock()`——提示永远消不掉，棋盘永远看不全。

这个补丁**转的是画面，不是设备**：点一下「一键横屏」，整个页面旋转 90° 并按可见视口尺寸重排，
在没有自动转屏的浏览器里也能横着玩；设备真的横过来时自动恢复。

> [!IMPORTANT]
> 非官方同人补丁，与鹰角网络、Yostar 及其关联方没有任何关系。《明日方舟》相关名称、角色、美术、音乐、
> 文本与数据版权归原权利人所有，**不适用**本仓库的 GPL-3.0 许可证。仅供学习交流与个人非商业使用，
> **严禁任何形式的盈利**。详见 [NOTICE.md](NOTICE.md)。

## 它做了什么

| 改了什么 | 效果 |
|---|---|
| **新增** `public/js/ui/landscape.js` | 旋转画面的全部逻辑：`<html class="sp-force-landscape">` + CSS transform，尺寸取自真实可见视口（`--app-w` / `--app-h`） |
| 提示层 | 原来的「请将设备横屏」多两个按钮：**一键横屏**、**全屏** |
| 设置 | 新增「强制横屏」开关（`sp.pref.landscape`），下次打开仍然生效 |
| 对局 HUD 角 / 标题画面 | 各有一个旋转按钮，随手可切 |
| `css/devices.css` / `components.css` / `css/screens/*` | 旋转态下的布局、安全区、HUD 与提示层样式 |
| `i18n/{zh-TW,en,ja,ko}.json` | 新增文案的四种语言翻译 |
| `docs/PLAYING.md` | 玩法说明补充横屏操作 |

### 为什么改了这么多 API

旋转过的 `<body>` 会和所有 DOM 坐标 API 脱节：`getBoundingClientRect()`、指针事件的 `clientX/clientY`、
`elementFromPoint()`、`innerWidth/innerHeight` 全部落到「未旋转的视口」，而游戏自己的布局活在「已旋转的 app 帧」里。
所以补丁在旋转期间临时阴影（shadow）四个原型，把坐标双向换算——**游戏本体一行都不用改**，
关掉横屏就立刻还原：

1. `Element.prototype.getBoundingClientRect` → 换算回 app 帧的矩形（画布、HUD、tooltip 锚点）
2. `window` 捕获阶段的指针 / 鼠标 / 滚轮事件 → 改写 `clientX/clientY`（含 `x/y`、`pageX/pageY` 别名）
3. `Document.prototype.elementFromPoint` / `elementsFromPoint` → 视口点反算 app 帧点
4. `window.innerWidth/innerHeight`、`visualViewport.{width,height,offsetTop,offsetLeft}` → app 帧尺寸

「一键横屏」按钮会在点击手势内先请求全屏 + 原生方向锁定，等视口稳定（260 ms）后再旋转画面；
否则浏览器会先转再转回来。旋转只是「愿望」：只要检测到设备屏幕本来就不是竖屏，旋转自动取消。

## 安装

补丁包只覆盖 **17 个文件**（1 个新增 + 16 个替换），约 640 KB，不需要上传完整包、不动
`node_modules` / `public/assets`、不用 `npm ci`、不用联网。

### 方式一：增量补丁（推荐，已有 v0.3.0 安装）

```bash
# 1) 把补丁包上传到服务器（宝塔：/www/wwwroot/）
#    或者直接从本仓库 Release 下载：
#    curl -L -o /www/wwwroot/stronghold-v0.3.0-landscape-patch.tar.gz \
#      https://github.com/xyss415/stronghold-landscape/releases/latest/download/stronghold-v0.3.0-landscape-patch.tar.gz

# 2) 执行部署脚本（root）
cd /www/wwwroot && bash deploy-landscape-patch.sh

# 自定义安装目录 / 包路径
bash deploy-landscape-patch.sh --install /www/wwwroot/game-stronghold --pkg /root/patch.tar.gz
```

脚本会：检查是否 v0.3.0 → 备份当前代码（几百 KB）→ 停服务 → 覆盖解压 → 修权限 → 起服务并验证
`/healthz`、`/js/ui/landscape.js`、`/data/config.json`、`/studio/` → 打印一键回滚命令。
**会结束正在进行的对局（游戏无存档），请在没人玩的时候执行。**

### 方式二：完整包（全新安装 / 不想打补丁）

用横屏完整包 `stronghold-v0.3.0-full-landscape.tar.gz`（约 780 MB，见 Release 资产或上游仓库），
按上游 [README · 快速开始](https://github.com/sganggs/Stronghold-Protocol#快速开始) 部署即可。

### 验证

```bash
curl -s http://127.0.0.1:3001/healthz
curl -s http://127.0.0.1:3001/js/ui/landscape.js | grep -c sp-force-landscape   # 应为 1
```

浏览器用**无痕窗口或 Ctrl+F5** 打开（旧缓存会显示老界面）。手机上竖屏打开 → 点「一键横屏」。

### 回滚

```bash
systemctl stop stronghold
tar -xzf /www/backup/stronghold-code/code-v0.3.0-before-landscape-<时间戳>.tar.gz -C /www/wwwroot/game-stronghold
rm -f /www/wwwroot/game-stronghold/public/js/ui/landscape.js
systemctl start stronghold
```

## 兼容性（重要）

补丁和**确切的一个版本**绑定：包内 `MANIFEST.json` 记录着 v0.3.0 每个文件的 `size` / `sha256`，
服务端更新校验也按版本进行。所以：

- ✅ 只适用于 **v0.3.0**（`deploy-landscape-patch.sh` 会先检查 `package.json` 的 version，不匹配直接中止）
- ❌ 不能套到 0.3.1 / 0.4.0 上（上游一发新版就会失效）
- 🔁 上游发新版后，用 [`tools/rebuild-landscape.py`](tools/rebuild-landscape.py) 把改动**重定基**到新版：

```bash
python rebuild-landscape.py --ours stronghold-v0.3.0-landscape-patch.tar.gz \
                            --new  stronghold-v0.3.1-full.tar.gz \
                            --out-dir dist/
```

它对「两边都改过」的文件做三方合并（`git merge-file`），新文件原样带过去，按新版重算 `MANIFEST.json`，
然后产出新的增量补丁包与完整包；冲突会写进工作目录并停下来等你手工改完（`--resolved` 继续）。

## 仓库结构

```
.
├─ patch/                        # 镜像游戏安装目录，17 个文件就是补丁的全部内容
│  ├─ MANIFEST.json              #   v0.3.0 文件清单 + size/sha256（服务端校验用）
│  ├─ docs/PLAYING.md
│  └─ public/{index.html,css,js,i18n}/
├─ deploy/deploy-landscape-patch.sh
├─ tools/
│  ├─ build-patch.ps1            # 打包 patch/ → dist/*.tar.gz + SHA256SUMS
│  ├─ build-patch.sh             # 同上（Linux / CI 用）
│  └─ rebuild-landscape.py       # 重定基到上游新版
├─ docs/INSTALL.md               # 详细安装 / 排错
├─ dist/                         # 打包产物（不进 git）
├─ LICENSE                       # GPL-3.0-or-later（继承上游）
└─ NOTICE.md                     # 素材与权利声明
```

## 打包与发布

```powershell
powershell -NoProfile -File tools\build-patch.ps1
# → dist/stronghold-v0.3.0-landscape-patch.tar.gz + dist/SHA256SUMS.txt
# （Windows 自带的是 powershell；装了 PowerShell 7 才可以用 pwsh）
```

打 tag 后 GitHub Actions 会自动打包并创建 Release（见 `.github/workflows/release.yml`）：

```bash
git tag -a v0.3.0-ls1 -m "landscape patch for app 0.3.0"
git push origin v0.3.0-ls1
```

> 单文件 >100 MB 会被 GitHub 直接拒绝 push，仓库里只放源码；完整包（~780 MB）放 Release 资产
> （单个资产上限 2 GB），不要进 git 历史。

## 已知限制

- 只处理「画面旋转」，不处理 iPhone 刘海 / 安全区之外的系统 UI 方向；旋转期间长按菜单、输入法弹窗位姿依赖浏览器实现。
- 旋转态下画布按新视口重新排布，极低端机第一次切换可能掉几帧。
- 只对 v0.3.0 生效；补丁走的是覆盖文件，不能和同样改这些文件的其他补丁共存。
- 由于改的是游戏本体文件，**没有**打包成 0.3.0 的插件系统（`plugins/*/plugin.json`）里的 UI 插件；
  那种形态只能操作 DOM，够不到渲染层的坐标换算。

## 许可

- 本仓库**自己编写的代码**（`public/js/ui/landscape.js`、脚本、工具）：**GPL-3.0-or-later**，见 [LICENSE](LICENSE)。
- 补丁其余内容是上游 v0.3.0 的**修改副本**，同样按上游的 GPL-3.0-or-later 授权分发。
- 《明日方舟》素材（名称、角色、美术、音乐、文本、数据）版权归原权利人，**不适用 GPL**，见 [NOTICE.md](NOTICE.md)。

## 相关

- 上游项目：[sganggs/Stronghold-Protocol](https://github.com/sganggs/Stronghold-Protocol) · [v0.3.0](https://github.com/sganggs/Stronghold-Protocol/releases)
- 上游文档：`docs/PLUGINS.md`（插件系统）、`docs/DEPLOY.md`（部署）、`docs/PLUGIN-GUIDE.md`（写插件）
- 本补丁的版本号约定：`v<上游版本>-ls<n>`，例如 `v0.3.0-ls1`
