# ScreenOCR

iOS 越狱插件（Theos Tweak）：**深链接 / 双指长按 → 全屏抓图 → Vision 离线 OCR → 浮层里直接编辑 / 复制 / 分享**。

- 触发：`prefs:root=axsocr_recognize`（与 GesturePro 预设链接一致）、`app-prefs:root=axsocr_recognize`、`screenocr://recognize`，或双指长按 0.4s
- 识别：系统 `Vision`，跑在独立进程 `/usr/libexec/ScreenOCRHelper` 里，**不在 SpringBoard 里加载模型**
- 抓图：私有 `_UICreateScreenUIImage()`（含状态栏、键盘），失败回退 `UIGetScreenImage`，最后才渲染 key window
- 结果：可编辑、复制、全选、框选局部重识别、系统分享
- 日志：`/var/mobile/Library/Logs/ScreenOCR.log`，随时能确认插件是否真的在工作

---

## 1. 为什么这么改（2.0 的关键变化）

| 问题 | 1.x 的做法 | 2.0 的做法 |
|---|---|---|
| 不知道插件有没有生效 | 只有 NSLog，需要连 Mac 看 Console | 每个进程加载、挂手势、收触发、截图、识别都写文件日志 |
| 双指长按不触发 | 只在 `makeKeyAndVisible` 后挂，且要求 `isKeyWindow` 已经为真 | 去掉该前置判断，另加启动后 1.5s / 3.0s 两次兜底挂载 |
| GesturePro 绑了链接没反应 | 没实现深链接 | hook `SpringBoard -applicationOpenURL:`（GesturePro 就是直接调它）+ `UIApplication -openURL:options:completionHandler:` |
| SpringBoard 里跑 Vision 会崩 | 在进程内跑 | 截图存 png，`posix_spawn` helper 进程识别，崩了只影响这一次 |

> `prefs:` 链接必须被**消费掉**，否则系统会真的跳去「设置」。所以命中后直接 return，不再走 `%orig`。

---

## 2. 工程结构

| 文件 | 作用 |
|---|---|
| `Tweak.xm` | Logos 入口：SpringBoard / UIApplication 的 URL hook、`UIWindow` 挂手势、加载日志 |
| `OCRTrigger.h/.m` | 深链接解析（`prefs:` / `app-prefs:` / `screenocr:`）、去重、启动识别 |
| `OCRGesture.h/.m` | 双指长按，触发时只发一条 `prefs:root=...`，不跑识别 |
| `OCRCapture.h/.m` | 整屏抓图（dlsym 取私有 API）+ 归一化坐标裁剪 |
| `OCREngine.h/.m` | 截图落盘 → `posix_spawn` helper → 读 stdout，25s 超时 |
| `OCRResultViewController.h/.m` | 结果浮层：编辑、复制/全选/框选/分享、键盘避让、Toast |
| `OCRConfig.h` | 触发词、冷却、手势参数、语言、黑名单 |
| `OCRLog.h` | 文件日志（400KB 自动滚动） |
| `helper/ScreenOCRHelperMain.m` | 独立进程里的 Vision：8 种配置依次降级（精确/快速 × CPU/默认 × CGImage/自建 buffer） |
| `ScreenOCR.plist` | `Filter = { Mode = "Any"; }`，App 进程要挂手势，所以不能只注入 SpringBoard |

---

## 3. 编译

需要 macOS + [Theos](https://theos.dev)（`$THEOS` 已配置）+ iOS SDK。

```bash
sh build.sh rootless                                   # Dopamine / palera1n rootless
sh build.sh rootful                                    # 有根
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

产物：

```
packages/com.359266613.screenocr_<version>_iphoneos-arm64.deb
  └─ /var/jb/Library/MobileSubstrate/DynamicLibraries/ScreenOCR.dylib
  └─ /var/jb/Library/MobileSubstrate/DynamicLibraries/ScreenOCR.plist
  └─ /var/jb/usr/libexec/ScreenOCRHelper          # Vision 识别进程
```

GitHub Actions 也是这套（`.github/workflows/build.yml`），push 到 `main` 自动出包并发布 Release。

---

## 4. 用 GesturePro 绑手势（推荐）

1. GesturePro → 选一个手势（如「底部栏双指长按」）
2. 动作类型选 **预设链接 / 打开 URL**
3. 填：

```
prefs:root=axsocr_recognize
```

4. 保存后在手势上试一次，屏幕会先收起可能存在的旧浮层，0.2s 后整屏截图并弹出识别结果

也可以用快捷指令或任何能开 URL 的工具，把 `screenocr://recognize` 当触发词。

---

## 5. 排查：怎么确认插件真的生效

装完先重启一次桌面（或 `killall -9 SpringBoard`），然后打开 Filza 看：

```
/var/mobile/Library/Logs/ScreenOCR.log
```

| 日志 | 含义 |
|---|---|
| `loaded: com.apple.springboard` | 插件已注入 SpringBoard |
| `springboard ready, trigger = prefs:root=axsocr_recognize` | 触发通道就绪 |
| `trigger: url=prefs:root=axsocr_recognize` | 收到了深链接 ✅ |
| `trigger: ignored, too soon` | 0.6s 内重复触发，被去重 |
| `capture: ok size={1170, 2532}` | 抓图成功 |
| `recognize done: 123 chars, 480 ms` | 识别完成 |
| `helper missing` | deb 没装全，`/var/jb/usr/libexec/ScreenOCRHelper` 不存在 |
| `helper crashed: signal ...` | Vision 崩了，日志里会带具体配置 |
| `gesture attached: ...` | 双指长按挂上了（只对 App 进程） |

**日志里没有任何 `loaded:`** → 插件根本没被加载：确认 deb 架构（`iphoneos-arm64`）、确认注入框架是 ElleKit / MobileSubstrate 且已启用。

**有 `trigger:` 但没有 `capture:`** → `_UICreateScreenUIImage` 不可用，日志会写 `private ... not found`，此时回退的窗口渲染在 SpringBoard 里可能是空图。

---

## 6. 已知限制

- 视频 DRM 界面、银行类 secure 界面抓到的是黑图，像素层面就没有内容，任何截图方案都一样
- 密码框只能识别成圆点
- 系统设置（`com.apple.Preferences`）默认不挂手势，避免和系统手势打架；深链接触发不受影响
- 私有 API 仅越狱可用，不可能上 App Store
