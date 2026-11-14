#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <unistd.h>
#import "AxsScreenOcrCapture.h"
#import "AxsScreenOcrConfig.h"
#import "AxsScreenOcrLog.h"
#import "AxsScreenOcrPrivate.h"
#import "AxsScreenOcrTrigger.h"


// 只在 SpringBoard 里注入：截图、弹浮层、响应深链接都由它完成。
// GesturePro 的「预设链接」动作直接调用 -[SpringBoard applicationOpenURL:]，
// 所以 hook 点必须落在这里，而不是 App 自己的 UIApplication。
%hook SpringBoard

// 与 GesturePro 头文件声明一致：返回 void，不调用 %orig 即视为消费了这条 URL。
- (void)applicationOpenURL:(id)url {
    if (axs_screenocr_handle_url((NSURL *)url)) {
        return;
    }
    %orig;
}

%end

%hook UIApplication

- (void)openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options
        completionHandler:(void (^)(BOOL success))completion {
    if (axs_screenocr_handle_url(url)) {
        if (completion) completion(YES);
        return;
    }
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        // 只读快照，不写默认值；配置文件由设置面板单独维护。
        [AxsScreenOcrConfig axs_screenocr_shared];

        axs_screenocr_log(@"loaded: %@ pid=%d", [NSBundle mainBundle].bundleIdentifier, getpid());

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            Class springBoardClass = objc_getClass("SpringBoard");
            BOOL hasOpenURL = springBoardClass &&
                class_getInstanceMethod(springBoardClass, @selector(applicationOpenURL:)) != NULL;
            axs_screenocr_log(@"self-check: SpringBoard=%@ applicationOpenURL:=%d",
                              NSStringFromClass(springBoardClass), hasOpenURL);
            axs_screenocr_log(@"self-check: capture=%d enabled=%d trigger=prefs:root=%@",
                              axs_screenocr_capture_available(),
                              [[AxsScreenOcrConfig axs_screenocr_shared] axs_screenocr_isEnabled],
                              axs_screenocr_trigger_token());
        });
    }
}
