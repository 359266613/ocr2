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

三条通道互相独立，任意一条命中即可触发。收到通知不代表 OCR 成功；需要实际识别到文字并核对准确性。

## 工程结构

```text
Hooks/AxsScreenOcrMain.xm              SpringBoard / UIApplication 深链接 hook 与启动自检
Headers/AxsScreenOcrPrivate.h          SpringBoard 与私有方法的必要声明
Sources/AxsScreenOcrTrigger.*          URL 匹配与去重
Sources/AxsScreenOcrRunner.*           抓图 -> 识别 -> 浮层 的编排
Sources/AxsScreenOcrCapture.*          _UICreateScreenUIImage / UIGetScreenImage 与窗口兜底
Sources/AxsScreenOcrRecognizer.*       启动 helper、读取并校验结果
Sources/AxsScreenOcrResultController.* 结果浮层（复制 / 全选 / 分享 / 关闭）
Sources/AxsScreenOcrLog.*              落盘日志
Sources/AxsScreenOcrConfig.*           配置快照（只读）
Sources/AxsScreenOcrPreferences.h      配置读写（唯一写入方是设置面板）
Sources/AxsScreenOcrPaths.h            资源与用户目录路径
AxsScreenOcrHelper/                    独立识别进程，安装到 /usr/libexec
Shared/AxsScreenOcrVision.*            helper 与设置进程对照共用的 Vision 核心
AxsScreenOcrPrefs/                     PreferenceBundle
layout/                                PreferenceLoader 入口
```

正式识别的 Vision 只在独立 helper 内运行。设置面板的显式环境对照测试也使用该核心，但在设置进程执行。SpringBoard 不链接、不调用 Vision；helper 崩溃或超时不在 SpringBoard 内重试。

## 识别后端

核心依据 ShellX 已核实的分支使用 Accurate、iOS 16 revision 3（旧系统 revision 2）、最小文字高度 `0.0035` 和系统默认计算后端。中文按首选语言选择简体或繁体，再加入英文，关闭语言纠正；非中文按首选语言筛选并启用语言纠正。iOS 17 非中文、iOS 18 及以上按已分析分支启用自动语言检测，不强制 CPU，不增加识别引擎。

先归一化 EXIF 方向，再将高图按原始分辨率分为 2 或 3 段，每段两侧各扩展段高的 18%，映射整图坐标并去重。第一块失败即停止，不对同一模型错误重复跑其他块。空结果和框架失败分别处理。completion handler 与 `performRequests:error:` 两条错误通道均记录，保留 domain、code 和底层错误。

这仍不等于完整复刻 ShellX：CoreImage 归一化替代其 UIKit 重绘，文本分段、去重和阅读顺序尚未逐项还原，helper 的执行环境也不同。目前不能保证修复设备上的模型加载失败。结果管道只接收 stdout，helper 的 stderr 写入 `AxsScreenOcrHelper.log`；请求权限声明不等于系统实际授予权限。

主日志记录截图尺寸和组件状态，不保存识别正文。截图临时写入缓存目录，正常完成、失败或超时后删除；如果 SpringBoard 本身意外退出，临时文件可能残留。

## 环境对照

安装构建产物后，先在设置面板点击「Vision 环境对照测试」。此测试不依赖插件启用开关，不触发 SpringBoard 截图。它生成一张系统字体中英文测试图，把同一个 PNG、同一份核心和单次整图模式依次用于 helper 与设置进程。测试结束删除图片，日志保存到：

```
/var/mobile/Library/Logs/AxsScreenOcrVisionDiagnostic.log
/var/mobile/Library/Logs/AxsScreenOcrHelper.log
```

日志记录进程、系统、语言、请求配置、阶段边界和错误；仅诊断合成图会记录文字结果。设置进程直接加载模型，若框架崩溃可能退出设置。进入模型前同步写入阶段日志，以便识别最后执行位置；此时合成图可能残留在设置临时目录。

- 设置成功、helper 失败：优先调查 helper 宿主环境，不能据此立即断言具体缺哪项权限。
- 两侧失败：检查两条错误通道，不能归因于 helper 独有问题。
- 两侧返回文字：先核对中英文内容，再测试实际截图和分块；不等于问题已修复。

如设置退出，提供上述两个日志和对应 Preferences 崩溃报告；不要反复测试 SpringBoard 内的 Vision。对照不自动切换正式识别后端，也不证明 ShellX 在设备上的实际执行宿主。

## 回归测试

macOS/Xcode 环境运行 `sh Tests/run-macos-tests.sh`，覆盖语言与错误链策略；CI 在打包前执行。可显式运行 `sh Tests/run-macos-tests.sh --smoke`，在 Mac 上调用真实 Vision 检查高图与八种 EXIF 方向。Mac 测试不能替代 iPhone 实机验证。

`Tests/check-ios-syntax.py` 可选使用 Python libclang 配合 `--sdk` 和 `--headers` 检查 Objective-C 语法。`--headers` 需包含编译器资源头文件及 Theos 依赖头文件；检查面板控制器还需 Preferences 头文件。缺少生成的 NEON 头文件时可显式加 `--without-neon`，但此时只是关闭该头文件分支的有限语法检查，不是完整设备编译。

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
| `helper pass` | 独立进程返回的行数或错误 |
| `helper terminated by signal` | 独立识别进程因信号退出 |
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
