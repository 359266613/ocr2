//
//  OCRCapture.m
//  ScreenOCR
//

#import "OCRCapture.h"
#import "OCRConfig.h"
#import <dlfcn.h>

// UIKit 私有函数：抓整屏，返回包含状态栏 / 键盘 / 所有窗口的图像。
// 用 dlsym 取而不是直接声明，符号不存在时只是截不到图，不会加载失败。
typedef UIImage *(*OCRScreenUIImageFunc)(void);
typedef CGImageRef (*OCRScreenImageFunc)(void);

static OCRScreenUIImageFunc OCRScreenUIImage(void) {
    static OCRScreenUIImageFunc function;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        function = (OCRScreenUIImageFunc)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
        if (!function) {
            OCRLog(@"private _UICreateScreenUIImage not found, will fall back");
        }
    });
    return function;
}

static OCRScreenImageFunc OCRScreenCGImage(void) {
    static OCRScreenImageFunc function;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        function = (OCRScreenImageFunc)dlsym(RTLD_DEFAULT, "UIGetScreenImage");
    });
    return function;
}

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
    // 1. 私有 API：整屏抓图（含状态栏、键盘、其他进程内容）
    OCRScreenUIImageFunc createImage = OCRScreenUIImage();
    if (createImage) {
        @try {
            UIImage *image = createImage();
            if (image.CGImage) {
                OCRLog(@"capture via _UICreateScreenUIImage, size=%@", NSStringFromCGSize(image.size));
                return image;
            }
            OCRLog(@"capture: _UICreateScreenUIImage returned empty image");
        } @catch (NSException *exception) {
            OCRLog(@"capture exception: %@", exception);
        }
    }

    // 2. 老接口兜底
    OCRScreenImageFunc createCGImage = OCRScreenCGImage();
    if (createCGImage) {
        @try {
            CGImageRef cgImage = createCGImage();
            if (cgImage) {
                UIImage *image = [UIImage imageWithCGImage:cgImage];
                CGImageRelease(cgImage);
                OCRLog(@"capture via UIGetScreenImage, size=%@", NSStringFromCGSize(image.size));
                return image;
            }
        } @catch (NSException *exception) {
            OCRLog(@"capture exception (UIGetScreenImage): %@", exception);
        }
    }

    // 3. 最后回退：渲染当前 key window。
    //    注意在 SpringBoard 里渲染自己的窗口拿不到前台 App 的内容，可能是一张空图。
    UIWindow *window = OCRKeyWindow();
    if (!window) {
        OCRLog(@"capture: no key window");
        return nil;
    }

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = UIScreen.mainScreen.scale;
    format.opaque = YES;

    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:window.bounds.size format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
    }];
    OCRLog(@"capture via window render (may be blank), size=%@", NSStringFromCGSize(image.size));
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
