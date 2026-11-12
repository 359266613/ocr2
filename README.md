# ScreenOCR

[![Build Deb](https://github.com/359266613/ocr2/actions/workflows/build.yml/badge.svg)](https://github.com/359266613/ocr2/actions/workflows/build.yml)

iOS 越狱插件（Theos Tweak）：**双指长按 → 全屏抓图 → Vision 离线 OCR → 浮层里直接编辑 / 复制 / 分享**。

- 识别引擎：系统 `Vision`（`VNRecognizeTextRequest`），完全本地，无网络、无模型文件
- 触发方式：任意界面**双指长按 0.4s**（可改）
- 抓图：优先私有 `_UICreateScreenUIImage()`（含状态栏、键盘），失败回退渲染 key window
- 附加能力：框选局部识别、结果二次编辑、一键复制、系统分享

支持 iOS 15.0+，arm64 / arm64e，同时提供**有根**与**无根**两种 deb。

---

## 一、直接安装

到 [Releases](https://github.com/359266613/ocr2/releases) 下载对应包：

| 越狱环境 | 文件名 | 架构 |
|---|---|---|
| unc0ver / checkra1n / Taurine 等有根越狱 | `..._iphoneos-arm.deb` | arm / arm64 |
| Dopamine / palera1n rootless 等无根越狱 | `..._iphoneos-arm64.deb` | arm64 / arm64e |

```bash
scp *.deb root@<device>:/var/mobile/
ssh root@<device> "dpkg -i /var/mobile/*.deb && killall -9 SpringBoard"
```

---

## 二、工程结构

| 文件 | 作用 |
|---|---|
| `Tweak.xm` | Logos 入口，hook `UIWindow` 的 `makeKeyAndVisible / makeKeyWindow / becomeKeyWindow`，给 key window 挂手势 |
| `OCRGesture.h/.m` | 手势安装（幂等、跳过非普通窗口、跳过黑名单 App） |
| `OCRCapture.h/.m` | 整屏抓图 + 归一化坐标裁剪 |
| `OCREngine.h/.m` | Vision 封装：语言过滤、按「上→下、左→右」拼行、主线程回调 |
| `OCRResultViewController.h/.m` | 结果浮层：UITextView 编辑、复制/全选/框选/分享、键盘避让、Toast、框选遮罩 |
| `OCRConfig.h` | 所有可调参数：手指数、长按时长、语言、黑名单、调试日志 |
| `ScreenOCR.plist` | 注入过滤（`Mode = Any`，注入所有带 UI 的进程） |
| `.github/workflows/build.yml` | CI：macOS runner 上装 Theos，矩阵构建 rootful / rootless，打 tag 自动发 Release |

为什么不用 `Filter = { Bundles = (com.apple.springboard) }`：App 在前台时触摸事件只走 App 自己的窗口，SpringBoard 根本收不到，手势不会触发。所以每个进程各自挂手势，抓图用整屏私有 API 保证拿到的是「屏幕上真实内容」。

---

## 三、本地编译

需要 macOS + [Theos](https://theos.dev)（`$THEOS` 已配置）+ iOS SDK。

```bash
make package FINALPACKAGE=1                                  # 有根
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless    # 无根
```

产物在 `packages/`。发布前记得改 `control` 里的 `Package / Maintainer / Author`。

---

## 四、CI

`.github/workflows/build.yml` 在以下时机触发：

- push 到 `main`
- 任意 PR
- 手动 `workflow_dispatch`
- 打 `v*` 标签（额外自动创建 Release 并附上两个 deb）

构建矩阵：

| flavor | 打包参数 | 产物架构 |
|---|---|---|
| rootful | 默认 | `iphoneos-arm` |
| rootless | `THEOS_PACKAGE_SCHEME=rootless` | `iphoneos-arm64` |

发布新版本：

```bash
git tag v1.0.0 && git push origin v1.0.0
```

---

## 五、调试

```bash
ssh root@<device> "log stream --predicate 'eventMessage CONTAINS \"[ScreenOCR]\"' --level debug"
```

会打印：注入的 Bundle ID、抓图路径与尺寸、Vision 支持语言、识别耗时。

---

## 六、已知限制（平台层面，不是 bug）

| 现象 | 原因 |
|---|---|
| 视频/银行类 App 抓到全黑 | 系统 `secure` 标记或 DRM 图层不参与截图，只能靠把该类 App 加进 `OCRBundleBlacklist` 规避 |
| 密码框识别成圆点 | 密码框渲染的就是圆点，像素层面没有明文 |
| 首次识别 200~600ms | Vision 模型冷启动，同进程后续识别明显更快 |
| `_UICreateScreenUIImage` 属私有 API | 越狱环境可用，**无法上架 App Store**；失效时自动回退到窗口渲染 |
| 注入范围大 | `Mode = Any` 覆盖所有进程，已用「是否存在 UIApplication」做保护，守护进程内不动作 |

---

## 七、可扩展方向

- **换触发方式**：改 `OCRConfig.h` 的手指数/时长；用音量键可在 `Tweak.xm` 里 hook SpringBoard 的 `SBVolumePressBriefly`
- **连续识别 / 自动翻译**：在 `OCRResultViewController.m` 的 `runOCRWithImage:` 回调里接翻译 API 或 `Translation` 框架
- **识别后直接复制退出**：删掉浮层，`UIPasteboard.generalPasteboard.string = text;`
- **偏好设置面板**：把 `OCRConfig.h` 的 inline 函数换成 `CFPreferencesCopyAppValue`，再配一个 PreferenceBundle
- **保留文字坐标**：`OCREngine` 里把 `VNRecognizedTextObservation.boundingBox` 一并返回，就能在浮层上画高亮框
