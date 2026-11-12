//
//  OCRGesture.m
//  ScreenOCR
//

#import "OCRGesture.h"
#import "OCRConfig.h"
#import "OCRResultViewController.h"
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
    if (!OCRProcessIsHostApp()) return;

    // 只挂普通窗口：跳过状态栏、键盘、以及我们自己的浮层
    if (window.windowLevel != UIWindowLevelNormal) return;
    if (!window.isKeyWindow) return;
    if (objc_getAssociatedObject(window, kOCRGestureKey)) return;

    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier ?: @"";
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

    OCRLog(@"gesture attached to %@ (%@)", window, bundleID);
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback prepare];
    [feedback impactOccurred];

    [OCRResultViewController captureAndPresentFromWindow:gesture.view.window];
}

#pragma mark - UIGestureRecognizerDelegate

// 和 App 自己的手势并存，不抢占
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

@end
