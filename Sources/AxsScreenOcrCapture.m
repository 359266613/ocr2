#import "AxsScreenOcrCapture.h"
#import "AxsScreenOcrLog.h"

#import <dlfcn.h>

// UIKit 私有截图接口不在公开 SDK 里，用 dlsym 在运行时取，
// 系统移除符号时自动走兜底，既不会链接失败也不会加载崩溃。
typedef UIImage *(*AxsScreenOcrCreateImageFunction)(void);
typedef CGImageRef (*AxsScreenOcrGetImageFunction)(void);

static AxsScreenOcrCreateImageFunction axsScreenOcrCreateImage = NULL;
static AxsScreenOcrGetImageFunction axsScreenOcrGetImage = NULL;
static dispatch_once_t axsScreenOcrSymbolOnce;

static void axs_screenocr_resolve_capture_symbols(void) {
    dispatch_once(&axsScreenOcrSymbolOnce, ^{
        axsScreenOcrCreateImage =
            (AxsScreenOcrCreateImageFunction)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
        axsScreenOcrGetImage =
            (AxsScreenOcrGetImageFunction)dlsym(RTLD_DEFAULT, "UIGetScreenImage");
    });
}

UIWindowScene *axs_screenocr_active_window_scene(void) {
    UIApplication *application = [UIApplication sharedApplication];
    UIWindowScene *fallback = nil;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
        if (!fallback) fallback = (UIWindowScene *)scene;
    }
    return fallback;
}

UIWindow *axs_screenocr_key_window(void) {
    UIWindowScene *scene = axs_screenocr_active_window_scene();
    if (!scene) return nil;

    UIWindow *candidate = nil;
    for (UIWindow *window in scene.windows) {
        if (window.isHidden || window.alpha <= 0.01) continue;
        if (!candidate || window.windowLevel >= candidate.windowLevel) {
            candidate = window;
        }
    }
    return candidate ?: scene.windows.firstObject;
}

BOOL axs_screenocr_capture_available(void) {
    axs_screenocr_resolve_capture_symbols();
    return axsScreenOcrCreateImage != NULL || axsScreenOcrGetImage != NULL;
}

UIImage *axs_screenocr_capture_screen(void) {
    axs_screenocr_resolve_capture_symbols();

    if (axsScreenOcrCreateImage) {
        @try {
            UIImage *image = axsScreenOcrCreateImage();
            if (image.CGImage) {
                axs_screenocr_log(@"capture: _UICreateScreenUIImage size=%@",
                                  NSStringFromCGSize(image.size));
                axs_screenocr_log(@"capture pixels=%zux%zu scale=%.2f orientation=%ld",
                                  CGImageGetWidth(image.CGImage), CGImageGetHeight(image.CGImage),
                                  image.scale, (long)image.imageOrientation);
                return image;
            }
        } @catch (__unused NSException *exception) {
            axs_screenocr_log(@"capture: _UICreateScreenUIImage threw");
        }
    }

    if (axsScreenOcrGetImage) {
        @try {
            CGImageRef imageRef = axsScreenOcrGetImage();
            if (imageRef) {
                UIImage *image = [UIImage imageWithCGImage:imageRef];
                CGImageRelease(imageRef);
                axs_screenocr_log(@"capture: UIGetScreenImage size=%@",
                                  NSStringFromCGSize(image.size));
                axs_screenocr_log(@"capture pixels=%zux%zu scale=%.2f orientation=%ld",
                                  CGImageGetWidth(image.CGImage), CGImageGetHeight(image.CGImage),
                                  image.scale, (long)image.imageOrientation);
                return image;
            }
        } @catch (__unused NSException *exception) {
            axs_screenocr_log(@"capture: UIGetScreenImage threw");
        }
    }

    UIWindow *window = axs_screenocr_key_window();
    if (!window) {
        axs_screenocr_log(@"capture: no window available");
        return nil;
    }

    // 兜底只能渲染本进程窗口，App 内容会是空白，仅用于确认链路仍在工作。
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = [UIScreen mainScreen].scale;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:window.bounds.size format:format];
    UIImage *image = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
    }];
    axs_screenocr_log(@"capture: window render fallback size=%@",
                      NSStringFromCGSize(image.size));
    if (image.CGImage) {
        axs_screenocr_log(@"capture pixels=%zux%zu scale=%.2f orientation=%ld",
                          CGImageGetWidth(image.CGImage), CGImageGetHeight(image.CGImage),
                          image.scale, (long)image.imageOrientation);
    }
    return image;
}
