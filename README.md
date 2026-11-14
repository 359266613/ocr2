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
Sources/AxsScreenOcrRecognizer.*       系统打开工作应用、等待并校验任务结果
Sources/AxsScreenOcrAppHost.*          记录前台应用、结果返回后尝试恢复
Sources/AxsScreenOcrResultController.* 结果浮层（复制 / 全选 / 分享 / 关闭）
Sources/AxsScreenOcrLog.*              落盘日志
Sources/AxsScreenOcrConfig.*           配置快照（只读）
Sources/AxsScreenOcrPreferences.h      配置读写（唯一写入方是设置面板）
Sources/AxsScreenOcrPaths.h            资源与用户目录路径
AxsScreenOcrWorker/                    UIKit 工作应用，安装到 /Applications
Shared/AxsScreenOcrVision.*            工作应用与设置进程对照共用的 Vision 核心
Shared/AxsScreenOcrIPC.*               UUID 任务、JSON 请求与结果、超时清理
AxsScreenOcrPrefs/                     PreferenceBundle
layout/                                PreferenceLoader 入口
```

正式识别的 Vision 只在独立 UIKit 工作应用内运行。设置面板的显式环境对照测试也使用该核心，但在设置进程执行。SpringBoard 不链接、不调用 Vision；工作应用崩溃或超时不在 SpringBoard 内重试。旧的命令行 helper、管道与 `posix_spawn` 路径已删除，不再作为兜底。

## 工作应用

安装时通过 `uicache -p` 注册 `com.axs.screenocr.worker`，桌面显示「全屏OCR工作器」。截图在切换应用前完成，随后系统通过 `axs-screenocr-worker://job/<UUID>` 打开工作应用。工作器使用 `UIApplicationMain`、正常 UIKit 生命周期和活动窗口，不再直接执行裸二进制。

此版本优先验证新的执行环境，会短暂切换到工作应用，并非无感后台 OCR。结果返回后，若当前前台仍是工作器，尝试恢复触发前的应用；如果用户已切换到其他应用，不强行抢回前台。无法取得原应用、原界面是主屏幕或恢复接口不可用时，可能停留在工作器，需要手动返回。恢复接口和新工作宿主都需实机验证，不能把设置进程的成功视为新应用必然成功。

任务位于 `/var/mobile/Library/Caches/AxsScreenOcrJobs/<UUID>/`，Roothide 按工具链转换路径。目录仅 mobile 可访问，输入与 JSON 文件限制大小，URL 不携带任意文件路径。工作器校验任务 ID、版本、方向、期限和截图尺寸，串行执行 Vision；不申请常驻后台权限。前台启动后申请有限后台任务时间，后台时间耗尽明确返回失败。

调用方最多等待 60 秒，区分系统拒绝启动、未接收任务和处理超时。完成、错误或超时后删除任务目录；工作器解码截图后立即删除任务截图文件，后续触发清理超过 180 秒的遗留任务。调用方或工作器意外退出时，清理可能延迟到下次启动。异常退出不会自动杀死、重启工作器，超时后可手动关闭工作器再试。

## 识别后端

核心依据 ShellX 已核实的分支使用 Accurate、iOS 16 revision 3（旧系统 revision 2）、最小文字高度 `0.0035` 和系统默认计算后端。中文按首选语言选择简体或繁体，再加入英文，关闭语言纠正；非中文按首选语言筛选并启用语言纠正。iOS 17 非中文、iOS 18 及以上按已分析分支启用自动语言检测，不强制 CPU，不增加识别引擎。

先归一化 EXIF 方向，再将高图按原始分辨率分为 2 或 3 段，每段两侧各扩展段高的 18%，映射整图坐标并去重。第一块失败即停止，不对同一模型错误重复跑其他块。空结果和框架失败分别处理。completion handler 与 `performRequests:error:` 两条错误通道均记录，保留 domain、code 和底层错误。

这仍不等于完整复刻 ShellX：CoreImage 归一化替代其 UIKit 重绘，文本分段、去重和阅读顺序尚未逐项还原。新 UIKit 宿主需要实机验证，不能保证已经修复设备上的模型加载失败。工作器的 stderr 与框架错误写入 `AxsScreenOcrWorker.log`；请求权限声明不等于系统实际授予权限。

主日志记录截图尺寸和组件状态，不保存识别正文。截图临时写入缓存目录，正常完成、失败或超时后删除；如果 SpringBoard 本身意外退出，临时文件可能残留。

## 环境对照

安装构建产物后，先确认桌面上有「全屏OCR工作器」，再在设置面板点击「Vision 环境对照测试」。此测试不依赖插件启用开关，不触发 SpringBoard 截图。它生成一张系统字体中英文测试图，把相同 PNG 字节、同一份核心和单次整图模式依次用于独立工作应用与设置进程；期间切换应用。测试结束删除图片，日志保存到：

```
/var/mobile/Library/Logs/AxsScreenOcrVisionDiagnostic.log
/var/mobile/Library/Logs/AxsScreenOcrWorker.log
```

日志记录进程、系统、语言、请求配置、阶段边界和错误；仅诊断合成图会记录文字结果。设置进程直接加载模型，若框架崩溃可能退出设置。进入模型前同步写入阶段日志，以便识别最后执行位置；此时合成图可能残留在设置临时目录。

- 设置成功、工作器失败：先区分应用启动/任务接收故障与模型加载失败，不能立即断言具体缺哪项权限。
- 两侧失败：检查两条错误通道，不能归因于某一个宿主独有问题。
- 两侧返回文字：先核对中英文内容，再测试实际截图和分块；不等于问题已修复。

如设置退出，提供上述两个日志和对应 Preferences 崩溃报告；不要反复测试 SpringBoard 内的 Vision。对照不自动切换正式识别后端，也不证明 ShellX 在设备上的实际执行宿主。

## 回归测试

按用户要求不运行静态检查，已移除本地语法检查脚本和 CI 中旧 helper 的检查步骤。原有运行时回归测试保留为手动选项：macOS/Xcode 环境运行 `sh Tests/run-macos-tests.sh` 覆盖语言与错误链策略；显式加 `--smoke` 在 Mac 上调用真实 Vision 检查高图与八种 EXIF 方向。CI 不自动运行这些测试。Mac 测试不能替代 iPhone 实机验证。

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
| `worker submit` | 已创建任务，准备通过系统打开 UIKit 工作应用 |
| `worker launch ... accepted=0` | 系统拒绝打开工作应用，检查注册与安装 |
| `worker acknowledged` | 工作应用已经读取任务 |
| `worker reply` / `worker pass` | 工作应用返回的行数或错误 |
| `worker timeout ... acknowledged=0` | 尚未收到接收任务记录，先排查启动与注册 |
| `worker timeout ... acknowledged=1` | 已接收但无结果，检查工作器日志和崩溃报告 |
| `recognize finished: N lines, M chars` | 识别完成 |
| `trigger ignored: plugin disabled` | 面板里没启用 |

排查顺序：有 `trigger:` 说明通道通，问题在截图/识别；只有 `self-check:` 说明触发没到，看 `hooks` 那行的三个数字哪个是 0。

## 构建

```sh
sh build.sh rootless
sh build.sh rootful rootless
sh build.sh roothide
```

本地需要已配置好的 Theos 与 iPhoneOS 16.5 SDK。工作器依赖系统应用注册工具 `uikittools`；deb 安装脚本根据 dpkg 记录的实际应用路径调用 `uicache`，不扫描随机越狱根目录。推送到 `main` 会触发 GitHub Actions，产物为 `packages/*.deb` 并自动创建 Release。

升级包将移除旧包内的 `/usr/libexec/AxsScreenOcrHelper`；原有 helper 日志保留，不参与新流程。新版本需要完整安装 deb，仅替换 dylib 不会安装或注册工作应用。

## 迁移说明

旧版包名是 `com.359266613.screenocr`，本版按插件命名约定改为 `com.axs.screenocr`，两者不是升级关系，安装前请先卸载旧包。设置默认关闭，装好首次使用需到「设置 → 全屏OCR」打开开关。
