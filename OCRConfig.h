//
//  OCRConfig.h
//  ScreenOCR
//
//  所有可调参数集中在这里，改完直接 make package 即可
//

#import <UIKit/UIKit.h>

/// 打开后会用 NSLog 打印注入进程、截图尺寸、识别耗时，方便 Console 里排查
NS_INLINE BOOL OCRDebugEnabled(void) { return YES; }

/// 触发手势：手指数量
NS_INLINE NSUInteger OCRTriggerTouchCount(void) { return 2; }

/// 触发手势：长按时长（秒）
NS_INLINE NSTimeInterval OCRTriggerDuration(void) { return 0.40; }

/// 触发手势：允许的漂移距离（pt），超过就取消，避免误触
NS_INLINE CGFloat OCRTriggerMaxMovement(void) { return 12.0; }

/// 识别语言优先级（Vision 不支持的语言会自动过滤掉）
NS_INLINE NSArray<NSString *> *OCRLanguages(void) {
    return @[ @"zh-Hans", @"zh-Hant", @"en-US" ];
}

/// 不希望挂手势的 App（Bundle ID），比如系统设置、银行类 App
/// 例：@[ @"com.apple.Preferences", @"com.icbc.iphoneclient" ]
NS_INLINE NSArray<NSString *> *OCRBundleBlacklist(void) {
    return @[ @"com.apple.Preferences" ];
}

/// 当前进程是否是「有界面的 App 进程」（守护进程里不挂手势，避免崩）
NS_INLINE BOOL OCRProcessIsHostApp(void) {
    static BOOL isApp;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
        isApp = (bundleID.length > 0) && ([UIApplication sharedApplication] != nil);
    });
    return isApp;
}

#define OCRLog(...) do { if (OCRDebugEnabled()) NSLog(@"[ScreenOCR] " __VA_ARGS__); } while (0)
