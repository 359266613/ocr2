//
//  OCRGesture.m
//  ScreenOCR
//
//  只做「识别手势 → 发一条深链接」这一件事。
//  截图 / Vision / 浮层全部交给 SpringBoard 进程，注入的 App 里不跑重活。
//

#import "OCRGesture.h"
#import "OCRConfig.h"
#import "OCRTrigger.h"
#import <objc/runtime.h>

static const void *kOCRGestureKey = &kOCRGestureKey;

@interface OCRGesture () <UIGestureRecognizerDelegate>
@end

@implementation OCRGesture

+ (instancetype)shared {
    static OCRGesture *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[OCRGesture alloc] init];
    });
    return instance;
}

- (void)attachToWindow:(UIWindow *)window {
    if (!window) return;
    if (OCRIsSpringBoard()) return;          // SpringBoard 里不挂，触摸到不了这里
    if (!OCRProcessIsHostApp()) return;

    // 只挂普通窗口：跳过状态栏、键盘、以及各种浮层
    if (window.windowLevel != UIWindowLevelNormal) return;
    if (objc_getAssociatedObject(window, kOCRGestureKey)) return;

    NSString *bundleID = OCRCurrentBundleID();
    if ([OCRBundleBlacklist() containsObject:bundleID]) return;

    UILongPressGestureRecognizer *gesture =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(handleLongPress:)];
    gesture.numberOfTouchesRequired = OCRTriggerTouchCount();
    gesture.minimumPressDuration = OCRTriggerDuration();
    gesture.allowableMovement = OCRTriggerMaxMovement();
    gesture.cancelsTouchesInView = NO;   // 触发时不吞掉 App 自己的触摸
    gesture.delaysTouchesEnded = NO;
    gesture.delegate = self;

    [window addGestureRecognizer:gesture];
    objc_setAssociatedObject(window, kOCRGestureKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    OCRLog(@"gesture attached: %@ key=%d level=%.1f window=%@",
           bundleID, window.isKeyWindow, window.windowLevel, NSStringFromClass(window.class));
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    OCRLog(@"gesture triggered in %@", OCRCurrentBundleID());

    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback prepare];
    [feedback impactOccurred];

    // 交给 SpringBoard 处理：走 openURL → SB 的 applicationOpenURL: / openURL: 被 hook 到
    NSString *link = [NSString stringWithFormat:@"prefs:root=%@", OCRTriggerToken()];
    NSURL *url = [NSURL URLWithString:link];
    if (!url) {
        OCRLog(@"gesture: bad trigger url %@", link);
        return;
    }

    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        OCRLog(@"gesture: openURL %@ -> %d", link, success);
    }];
}

#pragma mark - UIGestureRecognizerDelegate

// 和 App 自己的手势并存，不抢占
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

@end
