# 全屏OCR（ScreenOcr）

SpringBoard 侧的全屏文字识别插件。收到深链接后抓取整屏，交给独立进程做 Vision 离线识别，结果以浮层显示，可直接编辑、复制、分享。

- 包名：`com.axs.screenocr`
- 注入进程：`com.apple.springboard`
- 最低系统：iOS 15（rootless / roothide），iOS 14（rootful）

## 触发方式

### 深链接（GesturePro 等手势工具）

把动作设为「预设链接」，填写：

```
prefs:root=axsocr_recognize
```

也兼容 `axs_screenocr_recognize`、`axs-screenocr://recognize`、`screenocr://recognize`。
GesturePro 的「预设链接」直接调用 `-[SpringBoard applicationOpenURL:]`，插件在这个入口消费 URL，不会真的跳到「设置」。

插件同时挂了 `-[LSApplicationWorkspace openSensitiveURL:withOptions:]` 与 `-openURL:withOptions:`——iOS 16 上 `prefs:` 链接真正的打开入口，作为兜底。

### 通知通道（面板自测 / 脚本）

```
notifyutil -p com.axs.screenocr.trigger
```

或调用设置面板里的「测试触发一次识别」。

> **为什么面板测试不走深链接**：iOS 16 起 App 进程（含设置面板所在的 Preferences）调用 `-[UIApplication openURL:]` 打开 `prefs:` 会被系统直接拒绝，`completionHandler` 收到 `success = NO`，URL 根本不会交给 SpringBoard。之前版本的面板按钮因此必然弹「触发失败」，那是系统拦截，不是插件没生效。

三条通道互相独立，任意一条命中即可触发。设置面板测试成功，说明截图、识别、浮层整条链路都正常，剩下的只有手势工具那一侧。

## 工程结构

```text
Hooks/AxsScreenOcrMain.xm              SpringBoard / UIApplication 深链接 hook 与启动自检
Headers/AxsScreenOcrPrivate.h          SpringBoard 与私有方法的必要声明
Sources/AxsScreenOcrTrigger.*          URL 匹配与去重
Sources/AxsScreenOcrRunner.*           抓图 -> 识别 -> 浮层 的编排
Sources/AxsScreenOcrCapture.*          _UICreateScreenUIImage / UIGetScreenImage 与窗口兜底
Sources/AxsScreenOcrRecognizer.*       posix_spawn 启动 helper、读取并解析结果
Sources/AxsScreenOcrResultController.* 结果浮层（复制 / 全选 / 分享 / 关闭）
Sources/AxsScreenOcrLog.*              落盘日志
Sources/AxsScreenOcrConfig.*           配置快照（只读）
Sources/AxsScreenOcrPreferences.h      配置读写（唯一写入方是设置面板）
Sources/AxsScreenOcrPaths.h            资源与用户目录路径
AxsScreenOcrHelper/                    独立识别进程，安装到 /usr/libexec
AxsScreenOcrPrefs/                     PreferenceBundle
layout/                                PreferenceLoader 入口
```

Vision 不在 SpringBoard 里加载：模型在 helper 进程内运行，崩溃只影响单次识别。

## 日志

```
/var/mobile/Library/Logs/AxsScreenOcr.log
```

| 日志 | 含义 |
|---|---|
| `loaded: com.apple.springboard` | 插件已注入 |
| `self-check: hooks sbOptions=1 sensitive=1 workspaceOpen=1` | 三个 URL hook 都挂上了 |
| `self-check: ... capture=1` | 私有截图接口可用 |
| `trigger: prefs:root=axsocr_recognize` | 收到深链接 |
| `trigger: darwin notification ...` | 收到面板/脚本的通知触发 |
| `url seen via ...（未匹配触发词）` | URL 到了，但关键词不对 |
| `capture: _UICreateScreenUIImage size=...` | 抓图成功 |
| `recognize finished: N lines, M chars` | 识别完成 |
| `trigger ignored: plugin disabled` | 面板里没启用 |

排查顺序：有 `trigger:` 说明通道通，问题在截图/识别；只有 `self-check:` 说明触发没到，看 `hooks` 那行的三个数字哪个是 0。

## 构建

```sh
sh build.sh rootless
sh build.sh rootful rootless
sh build.sh roothide
```

本地需要已配置好的 Theos 与 iPhoneOS 16.5 SDK。推送到 `main` 会触发 GitHub Actions，产物为 `packages/*.deb` 并自动创建 Release。

## 迁移说明

旧版包名是 `com.359266613.screenocr`，本版按插件命名约定改为 `com.axs.screenocr`，两者不是升级关系，安装前请先卸载旧包。设置默认关闭，装好首次使用需到「设置 → 全屏OCR」打开开关。
