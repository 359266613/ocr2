//
//  Tweak.xm
//  ScreenOCR
//
//  1) 深链接触发：hook SpringBoard 私有的 applicationOpenURL:（GesturePro 的
//     「预设链接」动作就是直接调它），以及 UIApplication 的公开 openURL API。
//  2) 双指长按（可选）：注入到 App 进程后挂在 key window 上，触发时只负责
//     发一条 prefs:root=axsocr_recognize，真正的截图 / 识别全在 SpringBoard 里做。
//     这样 Vision 永远不在业务 App 里跑，某个 App 崩了也不影响系统。
//

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import "OCRConfig.h"
#import "OCRGesture.h"
#import "OCRTrigger.h"

#pragma mark - 深链接触发

%hook SpringBoard

// 私有方法，签名见 GesturePro 的 AxsPrivate.h
- (void)applicationOpenURL:(id)url {
    if ([url isKindOfClass:[NSURL class]] && OCRHandleTriggerURL((NSURL *)url)) {
        return;   // 消费掉，不要真的去打开「设置」
    }
    %orig;
}

%end

%hook UIApplication

- (void)openURL:(NSURL *)url options:(NSDictionary *)options
    completionHandler:(void (^)(BOOL))completion {
    if (OCRHandleTriggerURL(url)) {
        if (completion) completion(YES);
        return;
    }
    %orig;
}

%end

#pragma mark - 双指长按

%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;
    [[OCRGesture shared] attachToWindow:self];
}

- (void)makeKeyWindow {
    %orig;
    [[OCRGesture shared] attachToWindow:self];
}

- (void)becomeKeyWindow {
    %orig;
    [[OCRGesture shared] attachToWindow:self];
}

%end

#pragma mark - 加载日志

%ctor {
    @autoreleasepool {
        NSString *bundleID = OCRCurrentBundleID();
        OCRLog(@"loaded: %@ pid=%d", bundleID.length ? bundleID : @"(none)", getpid());

        if (OCRIsSpringBoard()) {
            // 关键自检：trigger 到底挂在哪、能不能截到屏，一次写清楚
            Class springBoardClass = NSClassFromString(@"SpringBoard");
            OCRLog(@"springboard ready, trigger = prefs:root=%@", OCRTriggerToken());
            OCRLog(@"self-check: SpringBoard=%@ applicationOpenURL:=%d UIApplication=%@ UIWindow=%@",
                   springBoardClass ?: @"nil",
                   springBoardClass && class_getInstanceMethod(springBoardClass, @selector(applicationOpenURL:)) ? 1 : 0,
                   [UIApplication class],
                   [UIWindow class]);
            OCRLog(@"self-check: _UICreateScreenUIImage=%d UIGetScreenImage=%d",
                   dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage") != NULL,
                   dlsym(RTLD_DEFAULT, "UIGetScreenImage") != NULL);
            return;
        }

        if (!OCRProcessIsHostApp()) return;
        if ([OCRBundleBlacklist() containsObject:bundleID]) {
            OCRLog(@"gesture skipped: %@ is blacklisted", bundleID);
            return;
        }

        // 兜底：有些 App 的 key window 在 hook 时机还没就绪，
        // 启动后补两次，确保手势真的挂上去了。
        for (NSNumber *delay in @[ @1.5, @3.0 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIWindow *window = [UIApplication sharedApplication].keyWindow;
                if (!window) {
                    window = [UIApplication sharedApplication].windows.firstObject;
                }
                if (window) {
                    [[OCRGesture shared] attachToWindow:window];
                } else {
                    OCRLog(@"gesture retry: no window yet in %@", bundleID);
                }
            });
        }
    }
}
