# 安装与排错

补丁包 = `stronghold-v0.3.0-landscape-patch.tar.gz`（约 640 KB，17 个文件）。
它只是**覆盖替换**若干文件，不安装依赖、不改数据库、不改 `package.json`。

## 0. 前提

- 服务器上已经装好**官方 v0.3.0**（安装目录里有 `server/index.js` 与 `package.json`，`version` 为 `0.3.0`）
- 有 root 权限（`systemctl`、`chown`）
- 默认路径 / 服务名（可用参数覆盖）：

| 变量 | 默认值 | 覆盖方式 |
|---|---|---|
| 安装目录 | `/www/wwwroot/game-stronghold` | `--install <目录>` |
| 补丁包 | `/www/wwwroot/stronghold-v0.3.0-landscape-patch.tar.gz` | `--pkg <路径>` |
| systemd 服务 | `stronghold` | 改脚本里的 `SVC` |
| 端口 | `3001`（读 `/etc/default/stronghold` 的 `PORT`） | 改 `/etc/default/stronghold` |
| 代码备份 | `/www/backup/stronghold-code/` | 改脚本里的 `BACKUP_DIR` |

## 1. 上传补丁

```bash
# 宝塔面板：文件 → /www/wwwroot/ → 上传
# 或者
scp stronghold-v0.3.0-landscape-patch.tar.gz root@HOST:/www/wwwroot/

# 直接拉 Release 资产
cd /www/wwwroot
curl -L -O https://github.com/xyss415/stronghold-landscape/releases/latest/download/stronghold-v0.3.0-landscape-patch.tar.gz
```

先看一眼内容（应当是 17 个文件、含 `public/js/ui/landscape.js`）：

```bash
tar -tzf stronghold-v0.3.0-landscape-patch.tar.gz | sort
```

## 2. 执行

```bash
cd /www/wwwroot
bash deploy-landscape-patch.sh
```

> ⚠️ 脚本会 `systemctl stop`，正在进行的对局会中断（游戏无存档）。请在没人玩的时候做。

脚本六步：检查前提 → 备份 → 停服务 → 覆盖解压 → 权限 → 起服务并自检。
任何一步失败都会中止并保留原状（解压失败会重启服务、告诉你回滚命令）。

## 3. 验证

```bash
systemctl is-active stronghold
curl -s http://127.0.0.1:3001/healthz
curl -s http://127.0.0.1:3001/js/ui/landscape.js | grep -c sp-force-landscape   # 1
```

浏览器侧（**必须**无痕窗口或 Ctrl+F5，老缓存会继续显示旧界面）：

1. 手机竖屏打开游戏 → 出现「请将设备横屏」→ 点「一键横屏」→ 画面旋转 90°
2. 进设置 → 打开「强制横屏」→ 刷新后仍然横着
3. 把手机真的横过来 → 自动恢复（不再强制旋转）
4. 对局里 HUD 角落的旋转按钮、标题画面的旋转按钮都能切

## 4. 回滚

```bash
systemctl stop stronghold
tar -xzf /www/backup/stronghold-code/code-v0.3.0-before-landscape-<时间戳>.tar.gz \
    -C /www/wwwroot/game-stronghold
rm -f /www/wwwroot/game-stronghold/public/js/ui/landscape.js
systemctl start stronghold
```

时间戳在脚本输出里（`已备份：...`）。备份只含代码（`MANIFEST.json docs public/{index.html,js,css,i18n}`），
几百 KB，可以留很多份。

## 5. 排错

| 现象 | 原因 / 处理 |
|---|---|
| `版本不匹配，已中止` | 安装目录不是 0.3.0。先装官方 0.3.0 完整包，再打补丁（安装目录未被改动） |
| `找不到安装目录` | 用 `--install` 指定，或确认游戏装在哪 |
| `补丁包内容不对（缺 public/js/ui/landscape.js）` | 上传错包（比如传了完整包或只传了一半）；重新 `tar -tzf` 检查 |
| 服务起不来 / `/healthz` 不通 | 脚本会打印 `journalctl -u stronghold -n 50` 与 `-error.log` 末 30 行，并按提示回滚 |
| 页面还是老样子 | 浏览器缓存。无痕窗口 / Ctrl+F5 / 清 CDN 缓存（宝塔反代开了缓存的话） |
| 页面旋转了但点不准 | 该浏览器的 `visualViewport` 行为异常；把浏览器、机型、系统版本开 Issue |
| 只想要「取消强制横屏」 | 设置里关掉开关，或回滚 |
| iPhone 全屏没反应 | iOS Safari 不支持元素全屏，属预期；旋转仍然可用 |

## 6. 卸载

等价于回滚：恢复备份并删掉新增文件即可。补丁没有写入任何配置、数据库或依赖。
