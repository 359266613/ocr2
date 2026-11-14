#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// 当前活跃的 UIWindowScene。SpringBoard 里可能有多个 scene，优先取前台活跃的那个。
FOUNDATION_EXPORT UIWindowScene * _Nullable axs_screenocr_active_window_scene(void);

// 当前最上层的可见窗口，用于兜底渲染与挂载浮层。
FOUNDATION_EXPORT UIWindow * _Nullable axs_screenocr_key_window(void);

// 整屏抓图（含状态栏、键盘等所有窗口内容）。失败返回 nil。
FOUNDATION_EXPORT UIImage * _Nullable axs_screenocr_capture_screen(void);

// 私有截图接口是否可用，用于启动自检日志。
FOUNDATION_EXPORT BOOL axs_screenocr_capture_available(void);

NS_ASSUME_NONNULL_END
