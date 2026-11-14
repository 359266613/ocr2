# 全屏OCR（ScreenOcr）

SpringBoard 侧的全屏文字识别插件。收到触发后抓取整屏，使用 Vision 离线识别，结果以浮层显示，可直接编辑、复制、分享。

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
Sources/AxsScreenOcrRecognizer.*       进程内 Vision 识别及 helper 兜底
Sources/AxsScreenOcrResultController.* 结果浮层（复制 / 全选 / 分享 / 关闭）
Sources/AxsScreenOcrLog.*              落盘日志
Sources/AxsScreenOcrConfig.*           配置快照（只读）
Sources/AxsScreenOcrPreferences.h      配置读写（唯一写入方是设置面板）
Sources/AxsScreenOcrPaths.h            资源与用户目录路径
AxsScreenOcrHelper/                    独立识别进程，安装到 /usr/libexec
AxsScreenOcrPrefs/                     PreferenceBundle
layout/                                PreferenceLoader 入口
```

Vision 优先在 SpringBoard 内运行；无结果时才启动 helper 兜底。进程内识别的崩溃可能影响 SpringBoard，需要真机验证稳定性。

## 识别后端

主路径使用 Accurate 模式，明确指定简体中文和英文，关闭自动语言检测。依次尝试 revision 2 的系统默认和 CPU 后端；iOS 16 及以上再尝试 revision 3 的两个后端，取得非空结果即停止。所有尝试均失败或无文字时才进入 helper。不同设备的后端可用性需要实机验证。

helper 仅在主路径无结果时运行，尝试降到 mobile 用户并使用 CPU 后端，按不同分辨率重试 Accurate。结果管道只接收 stdout，helper 的 stderr 写入 `AxsScreenOcrHelper.log`。

日志包含截图像素尺寸、请求 revision、支持语言、各次识别行数、中文字符数、异常字符数和平均置信度，不保存识别正文或主路径截图。helper 兜底会临时写入截图，调用结束后删除。

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
| `capture pixels=...` | 截图像素尺寸、缩放与方向 |
| `vision r2-default` / `vision r2-cpu` | 各 revision 和后端的请求配置、结果或错误 |
| `vision selected=...` | 最终使用的识别路径 |
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
