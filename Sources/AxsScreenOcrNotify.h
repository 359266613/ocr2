#pragma once

#import <Foundation/Foundation.h>

// 独立于 URL scheme 的触发通道。
//
// 为什么需要它：iOS 16 起 App 进程（包括设置面板所在的 Preferences）调用
// -[UIApplication openURL:] 打开 prefs: 链接会被系统直接拒绝，completionHandler
// 收到 success = NO，URL 根本不会交给 SpringBoard。所以面板里的「测试触发」
// 不可能靠 URL 验证插件是否生效，必须走一条不经过 URL 分发的通道。
//
// 这里用 Darwin 通知：任意进程 notify_post 都能送达，SpringBoard 侧注册监听后
// 直接开始识别。面板、脚本、其他插件都可以复用这条路。

static NSString * const AxsScreenOcrTriggerNotificationName __attribute__((unused)) =
    @"com.axs.screenocr.trigger";

static inline void axs_screenocr_post_trigger_notification(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)AxsScreenOcrTriggerNotificationName,
                                         NULL, NULL, true);
}

// Darwin 通知的 observer 参数直接携带 block，避免再引入一个全局变量。
static void axs_screenocr_trigger_notification_callback(CFNotificationCenterRef center,
                                                        void *observer,
                                                        CFNotificationName name,
                                                        const void *object,
                                                        CFDictionaryRef userInfo)
    __attribute__((unused));

static void axs_screenocr_trigger_notification_callback(CFNotificationCenterRef center,
                                                        void *observer,
                                                        CFNotificationName name,
                                                        const void *object,
                                                        CFDictionaryRef userInfo) {
    void (^handler)(void) = (__bridge void (^)(void))observer;
    if (handler) handler();
}

// 只在注入的 SpringBoard 进程里调用一次；block 由这里持有，避免被提前释放。
static inline void axs_screenocr_observe_trigger_notification(void (^handler)(void)) {
    static void (^sAxsScreenOcrTriggerHandler)(void) = nil;
    sAxsScreenOcrTriggerHandler = [handler copy];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge void *)sAxsScreenOcrTriggerHandler,
                                    axs_screenocr_trigger_notification_callback,
                                    (__bridge CFStringRef)AxsScreenOcrTriggerNotificationName,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
