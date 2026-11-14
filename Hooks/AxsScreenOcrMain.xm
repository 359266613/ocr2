#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <unistd.h>

#import "AxsScreenOcrCapture.h"
#import "AxsScreenOcrConfig.h"
#import "AxsScreenOcrLog.h"
#import "AxsScreenOcrNotify.h"
#import "AxsScreenOcrPrivate.h"
#import "AxsScreenOcrRunner.h"
#import "AxsScreenOcrTrigger.h"

// 只在 SpringBoard 里注入：截图、弹浮层、响应深链接都由它完成。
//
// 触发有三条通道，任意一条命中即可：
//   1. -[SpringBoard applicationOpenURL:]              GesturePro「预设链接」直接调用
//   2. -[LSApplicationWorkspace openSensitiveURL:withOptions:]
//      iOS 16 上 prefs: 链接真正的打开入口，SpringBoard 内部也走这里
//   3. Darwin 通知 com.axs.screenocr.trigger            面板「测试触发」用，绕开 URL 分发

#pragma mark - 动态 hook 辅助

// 只挂真实存在的方法：MSHookMessageEx 对不存在的 selector 会先 addMethod，
// %orig 变成 NULL，之后一旦走原流程就会崩。
static BOOL axs_screenocr_hook_method(Class cls, NSString *selectorName, IMP replacement, IMP *original) {
    if (!cls || selectorName.length == 0) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (!selector || !class_getInstanceMethod(cls, selector)) return NO;
    MSHookMessageEx(cls, selector, replacement, original);
    return YES;
}

typedef BOOL (*AxsScreenOcrURLBoolIMP)(id, SEL, id, id);
typedef void (*AxsScreenOcrURLVoidIMP)(id, SEL, id, id);

static AxsScreenOcrURLBoolIMP axs_screenocr_orig_open_sensitive = NULL;
static AxsScreenOcrURLBoolIMP axs_screenocr_orig_workspace_open = NULL;
static AxsScreenOcrURLVoidIMP axs_screenocr_orig_springboard_open_options = NULL;

#pragma mark - 动态挂载的 hook 实现

static BOOL axs_screenocr_open_sensitive(id self, SEL _cmd, id url, id options) {
    if (axs_screenocr_handle_url((NSURL *)url)) return YES;
    axs_screenocr_note_url((NSURL *)url, @"LSApplicationWorkspace -openSensitiveURL:withOptions:");
    return axs_screenocr_orig_open_sensitive
        ? axs_screenocr_orig_open_sensitive(self, _cmd, url, options)
        : NO;
}

static BOOL axs_screenocr_workspace_open(id self, SEL _cmd, id url, id options) {
    if (axs_screenocr_handle_url((NSURL *)url)) return YES;
    axs_screenocr_note_url((NSURL *)url, @"LSApplicationWorkspace -openURL:withOptions:");
    return axs_screenocr_orig_workspace_open
        ? axs_screenocr_orig_workspace_open(self, _cmd, url, options)
        : NO;
}

static void axs_screenocr_springboard_open_options(id self, SEL _cmd, id url, id options) {
    if (axs_screenocr_handle_url((NSURL *)url)) return;
    axs_screenocr_note_url((NSURL *)url, @"SpringBoard -applicationOpenURL:options:");
    if (axs_screenocr_orig_springboard_open_options) {
        axs_screenocr_orig_springboard_open_options(self, _cmd, url, options);
    }
}

#pragma mark - 静态 hook

// 与 GesturePro 头文件声明一致：返回 void，不调用 %orig 即视为消费了这条 URL。
%hook SpringBoard

- (void)applicationOpenURL:(id)url {
    if (axs_screenocr_handle_url((NSURL *)url)) {
        return;
    }
    axs_screenocr_note_url((NSURL *)url, @"SpringBoard -applicationOpenURL:");
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

        // 通道 3：面板「测试触发」直接投递，不经过 URL 分发，不受 scheme 限制。
        axs_screenocr_observe_trigger_notification(^{
            axs_screenocr_log(@"trigger: darwin notification %@", AxsScreenOcrTriggerNotificationName);
            [AxsScreenOcrRunner axs_screenocr_run];
        });

        Class springBoardClass = objc_getClass("SpringBoard");
        Class workspaceClass = objc_getClass("LSApplicationWorkspace");

        BOOL hookedSpringBoardOptions = axs_screenocr_hook_method(
            springBoardClass, @"applicationOpenURL:options:",
            (IMP)axs_screenocr_springboard_open_options,
            (IMP *)&axs_screenocr_orig_springboard_open_options);

        BOOL hookedSensitive = axs_screenocr_hook_method(
            workspaceClass, @"openSensitiveURL:withOptions:",
            (IMP)axs_screenocr_open_sensitive,
            (IMP *)&axs_screenocr_orig_open_sensitive);

        BOOL hookedWorkspaceOpen = axs_screenocr_hook_method(
            workspaceClass, @"openURL:withOptions:",
            (IMP)axs_screenocr_workspace_open,
            (IMP *)&axs_screenocr_orig_workspace_open);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            Class sb = objc_getClass("SpringBoard");
            BOOL hasOpenURL = sb && class_getInstanceMethod(sb, NSSelectorFromString(@"applicationOpenURL:")) != NULL;
            Class ws = objc_getClass("LSApplicationWorkspace");
            axs_screenocr_log(@"self-check: SpringBoard=%@ applicationOpenURL:=%d",
                              sb ? NSStringFromClass(sb) : @"nil", hasOpenURL);
            axs_screenocr_log(@"self-check: hooks sbOptions=%d sensitive=%d workspaceOpen=%d workspace=%@",
                              hookedSpringBoardOptions, hookedSensitive, hookedWorkspaceOpen,
                              ws ? NSStringFromClass(ws) : @"nil");
            axs_screenocr_log(@"self-check: capture=%d enabled=%d trigger=prefs:root=%@",
                              axs_screenocr_capture_available(),
                              [[AxsScreenOcrConfig axs_screenocr_shared] axs_screenocr_isEnabled],
                              axs_screenocr_trigger_token());
        });
    }
}
