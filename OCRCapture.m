//
//  OCRCapture.m
//  ScreenOCR
//

#import "OCRCapture.h"
#import "OCRConfig.h"

// UIKit 私有函数：抓整屏，返回包含状态栏 / 键盘 / 所有窗口的图像。
// 在越狱注入的 App 进程内可直接使用，比 drawViewHierarchyInRect 更完整。
extern UIImage *_UICreateScreenUIImage(void) __attribute__((weak_import));

UIWindow *OCRKeyWindow(void) {
    UIWindow *fallback = nil;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState != UISceneActivationStateForegroundActive &&
                windowScene.activationState != UISceneActivationStateForegroundInactive) {
                continue;
            }
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) return window;
                if (!fallback && window.windowLevel == UIWindowLevelNormal) fallback = window;
            }
        }
    }
    if (fallback) return fallback;
    return UIApplication.sharedApplication.keyWindow;
}

UIImage *OCRCaptureScreen(void) {
    // 1. 私有 API：整屏抓图
    if (_UICreateScreenUIImage) {
        @try {
            UIImage *image = _UICreateScreenUIImage();
            if (image.CGImage) {
                OCRLog(@"capture via _UICreateScreenUIImage, size=%@", NSStringFromCGSize(image.size));
                return image;
            }
        } @catch (NSException *exception) {
            OCRLog(@"capture exception: %@", exception);
        }
    }

    // 2. 回退：渲染当前 key window（拿不到状态栏，但正文完整）
    UIWindow *window = OCRKeyWindow();
    if (!window) return nil;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = UIScreen.mainScreen.scale;
    format.opaque = YES;

    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:window.bounds.size format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
    }];
    OCRLog(@"capture via window render, size=%@", NSStringFromCGSize(image.size));
    return image;
}

UIImage *OCRCropImage(UIImage *image, CGRect normalizedRect) {
    if (!image.CGImage) return nil;

    normalizedRect = CGRectIntersection(normalizedRect, CGRectMake(0, 0, 1, 1));
    if (CGRectIsEmpty(normalizedRect) ||
        normalizedRect.size.width < 0.01 || normalizedRect.size.height < 0.01) {
        return nil;
    }

    CGSize pixelSize = CGSizeMake(image.size.width * image.scale,
                                  image.size.height * image.scale);
    CGRect pixelRect = CGRectMake(normalizedRect.origin.x * pixelSize.width,
                                  normalizedRect.origin.y * pixelSize.height,
                                  normalizedRect.size.width * pixelSize.width,
                                  normalizedRect.size.height * pixelSize.height);
    pixelRect = CGRectIntersection(CGRectIntegral(pixelRect),
                                   CGRectMake(0, 0, pixelSize.width, pixelSize.height));
    if (CGRectIsEmpty(pixelRect)) return nil;

    CGImageRef subImage = CGImageCreateWithImageInRect(image.CGImage, pixelRect);
    if (!subImage) return nil;

    UIImage *cropped = [UIImage imageWithCGImage:subImage
                                           scale:image.scale
                                     orientation:image.imageOrientation];
    CGImageRelease(subImage);
    return cropped;
}
