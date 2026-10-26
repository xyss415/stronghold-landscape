# 更新日志

版本号约定：`v<上游版本>-ls<n>`，本补丁与上游版本严格绑定（`MANIFEST.json` 记录每个文件的 `size`/`sha256`）。

## v0.3.3-ls1 — 2026-10-26

对应上游 v0.3.3 的重定基版本。横屏功能本身没有变化，改动全部来自上游 0.3.2 / 0.3.3 的更新与三方合并。

**适配**

- 补丁重新基于上游 v0.3.3：`MANIFEST.json` 按 0.3.3 重算（7077 个文件），补丁仍为 17 个文件。
- 与上游 v0.3.3 在 5 个文件的同区改动已合并：`public/css/screens/draft.css`、
  `public/css/screens/game.css`、`public/js/main.js`、`public/js/screens/game.js`、
  `public/js/ui/settings.js`。
- 上游新增的 `--sp-ui` 界面缩放（`max(…, 32px, calc(… * var(--sp-ui, 1)))`）与横屏的
  `--app-w / --app-h` 应用帧尺寸叠在一起：两个弹层 / HUD 保持上游的新尺寸，同时仍按旋转后的可见视口收边。
- 上游 v0.3.3 新增的全屏 / 屏幕常亮（`useFullscreen`、`useScreenWakeLock`、`isCombatPhase`）与
  横屏模块共存；`main.js` 同时保留两边的 import 与 `installLandscape()` 调用。

**兼容**

- 只适用于上游 **v0.3.3**；从 v0.3.1 升级请先恢复/安装官方 v0.3.3，再打补丁。
- `deploy/deploy-landscape-patch.sh` 保持版本无关：从补丁包的 `MANIFEST.json` 读取所需版本，不匹配直接中止。
- `tools/rebuild-landscape.py` 修了官方 `.zip` 包在 `--resolved` 复查阶段的成员计数（之前会把 zip 当 tar.gz 打开）。

## v0.3.1-ls1 — 2026-10-18

对应上游 v0.3.1 的重定基版本。横屏功能本身没有变化，改动全部来自上游 0.3.1 的更新与三方合并。

**适配**

- 补丁重新基于上游 v0.3.1：`MANIFEST.json` 按 0.3.1 重算（6949 个文件），补丁仍为 17 个文件。
- 与上游 0.3.1 在 4 个文件的同区改动已合并：`docs/PLAYING.md`、`public/css/devices.css`、
  `public/js/screens/game.js`、`public/js/ui/settings.js`。
- `devices.css` 新增异形屏适配（`html[data-fit]`）后，旋转态仍用 `--app-w/--app-h` 计算 rem，
  避免两个功能同时开启时缩放被覆盖。

**兼容**

- 只适用于上游 **v0.3.1**；从 v0.3.0 升级请先恢复/安装官方 v0.3.1，再打补丁。
- `deploy/deploy-landscape-patch.sh` 改为版本无关：从补丁包的 `MANIFEST.json` 读取所需版本，不匹配直接中止。

## v0.3.0-ls1 — 2026-10-17

首个公开版本，对应上游 v0.3.0。

**新增**

- `public/js/ui/landscape.js`：一键横屏。旋转 `<html>`（`sp-force-landscape` + CSS transform），
  尺寸取自真实可见视口（`--app-w` / `--app-h`），不依赖系统自动转屏，也不需要 `screen.orientation.lock()`。
- 旋转期间临时阴影四个坐标 API：`Element.prototype.getBoundingClientRect`、`window` 捕获阶段的
  指针 / 鼠标 / 滚轮事件（改写 `clientX/clientY` 及 `x/y`、`pageX/pageY`）、
  `Document.prototype.elementFromPoint` / `elementsFromPoint`、
  `window.innerWidth/innerHeight` 与 `visualViewport.{width,height,offsetTop,offsetLeft}`；关闭横屏立刻还原。
- 提示层新增「一键横屏」「全屏」按钮；点击手势内先请求全屏 + 原生方向锁定，等视口稳定 260 ms 再旋转。
- 设置中新增「强制横屏」开关，偏好存 `sp.pref.landscape`；设备本来就不是竖屏时自动取消旋转。
- 对局 HUD 角落与标题画面新增旋转按钮。

**调整**

- `css/devices.css`：旋转态布局、安全区与提示层样式（14 处）。
- `css/components.css`、`css/screens/{game,draft,guide}.css`：旋转态下的组件与 HUD 细节。
- `i18n/{zh-TW,en,ja,ko}.json`：新增文案四种语言。
- `docs/PLAYING.md`：玩法说明补充横屏操作。
- `public/index.html`、`public/js/{main.js,screens/title.js,screens/game.js,ui/settings.js}`：接入新模块与按钮。

**已知问题**

- 只在 v0.3.0 上验证；上游发新版需用 `tools/rebuild-landscape.py` 重定基。
- iOS Safari 不支持元素全屏，全屏按钮无效（旋转不受影响）。
