//
//  Tweak.xm
//  ScreenOCR
//
//  注入到每个 App 进程（Filter Mode = Any），在 key window 上挂双指长按手势。
//  之所以不只在 SpringBoard 里做：App 在前台时触摸事件不会到 SpringBoard 的窗口。
//

#import <UIKit/UIKit.h>
#import "OCRConfig.h"
#import "OCRGesture.h"

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

- (void)setWindowLevel:(CGFloat)windowLevel {
    %orig;
    if (windowLevel == UIWindowLevelNormal) {
        [[OCRGesture shared] attachToWindow:self];
    }
}

%end

%ctor {
    if (!OCRProcessIsHostApp()) return;

    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier ?: @"";
    if ([OCRBundleBlacklist() containsObject:bundleID]) {
        OCRLog(@"skip blacklisted %@", bundleID);
        return;
    }
    OCRLog(@"loaded in %@", bundleID);
}
