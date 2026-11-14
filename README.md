# 全屏OCR（ScreenOcr）

SpringBoard 侧的全屏文字识别插件。收到深链接后抓取整屏，交给独立进程做 Vision 离线识别，结果以浮层显示，可直接编辑、复制、分享。

- 包名：`com.axs.screenocr`
- 注入进程：`com.apple.springboard`
- 最低系统：iOS 15（rootless / roothide），iOS 14（rootful）

## 触发方式

在 GesturePro 或其他支持深链接的工具里，把动作设为「预设链接」，填写：

```
prefs:root=axsocr_recognize
```

也兼容 `axs_screenocr_recognize`、`axs-screenocr://recognize`、`screenocr://recognize`。
插件通过 `-[SpringBoard applicationOpenURL:]` 消费该 URL，不会真的跳到「设置」。

设置面板里的「测试触发一次识别」走的是同一条链路，用来确认插件是否生效。

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
| `self-check: ... capture=1` | 私有截图接口可用 |
| `trigger: prefs:root=axsocr_recognize` | 收到深链接 |
| `capture: _UICreateScreenUIImage size=...` | 抓图成功 |
| `recognize finished: N lines, M chars` | 识别完成 |
| `trigger ignored: plugin disabled` | 面板里没启用 |

## 构建

```sh
sh build.sh rootless
sh build.sh rootful rootless
sh build.sh roothide
```

本地需要已配置好的 Theos 与 iPhoneOS 16.5 SDK。推送到 `main` 会触发 GitHub Actions，产物为 `packages/*.deb` 并自动创建 Release。

## 迁移说明

旧版包名是 `com.359266613.screenocr`，本版按插件命名约定改为 `com.axs.screenocr`，两者不是升级关系，安装前请先卸载旧包。设置默认关闭，装好首次使用需到「设置 → 全屏OCR」打开开关。
