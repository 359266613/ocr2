#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 触发关键词。GesturePro「预设链接」里填 prefs:root=axsocr_recognize 即可。
// 兼容旧值 axsocr_recognize 与新的 axs_screenocr_recognize。
FOUNDATION_EXPORT NSString *axs_screenocr_trigger_token(void);

FOUNDATION_EXPORT BOOL axs_screenocr_url_matches(NSURL * _Nullable url);

// 返回 YES 表示本插件消费了该 URL（调用方不应继续走系统打开流程）。
FOUNDATION_EXPORT BOOL axs_screenocr_handle_url(NSURL * _Nullable url);

NS_ASSUME_NONNULL_END
