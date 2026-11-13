//
//  OCRConfig.h
//  ScreenOCR
//
//  所有可调参数集中在这里，改完直接 make package 即可
//

#pragma once

#import <UIKit/UIKit.h>
#import "OCRLog.h"

/// ============ 触发方式 ============

/// 深链接触发词：prefs:root=axsocr_recognize（与 GesturePro 预设链接保持一致）
/// app-prefs:root=axsocr_recognize 同样有效；另外 screenocr://recognize 也能触发
static inline NSString *OCRTriggerToken(void) { return @"axsocr_recognize"; }

/// 触发去重时间窗（秒），避免手势连发两次
static inline NSTimeInterval OCRTriggerCooldown(void) { return 0.6; }

/// 触发后等多久再截图（给手势动画 / 收起浮层留时间）
static inline NSTimeInterval OCRTriggerCaptureDelay(void) { return 0.20; }

/// ============ 手势（可选，用 GesturePro 时用不到） ============

/// 触发手势：手指数量
static inline NSUInteger OCRTriggerTouchCount(void) { return 2; }

/// 触发手势：长按时长（秒）
static inline NSTimeInterval OCRTriggerDuration(void) { return 0.40; }

/// 触发手势：允许的漂移距离（pt），超过就取消，避免误触
static inline CGFloat OCRTriggerMaxMovement(void) { return 12.0; }

/// ============ 识别 ============

/// 识别语言优先级（Vision 不支持的语言会自动过滤掉）
static inline NSArray<NSString *> *OCRLanguages(void) {
    return @[ @"zh-Hans", @"zh-Hant", @"en-US" ];
}

/// 单次识别超时（秒），helper 卡住就杀掉
static inline NSTimeInterval OCRRecognizeTimeout(void) { return 25.0; }

/// ============ 屏蔽 ============

/// 不希望挂手势的 App（Bundle ID），比如系统设置、银行类 App
/// 例：@[ @"com.apple.Preferences", @"com.icbc.iphoneclient" ]
static inline NSArray<NSString *> *OCRBundleBlacklist(void) {
    return @[ @"com.apple.Preferences" ];
}

/// ============ 进程判定 ============

/// 当前进程 bundle id（守护进程里可能是 nil）
static inline NSString *OCRCurrentBundleID(void) {
    return [NSBundle mainBundle].bundleIdentifier ?: @"";
}

/// 是否是 SpringBoard 进程（深链接触发、截图、弹浮层都在这里做）
static inline BOOL OCRIsSpringBoard(void) {
    return [OCRCurrentBundleID() isEqualToString:@"com.apple.springboard"];
}

/// 当前进程是否是「有界面的 App 进程」（守护进程里不挂手势，避免崩）
static inline BOOL OCRProcessIsHostApp(void) {
    static BOOL isApp;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        isApp = (OCRCurrentBundleID().length > 0) && ([UIApplication sharedApplication] != nil);
    });
    return isApp;
}
