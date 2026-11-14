#import "AxsScreenOcrCapture.h"
#import "AxsScreenOcrLog.h"
#import "AxsScreenOcrPrivate.h"

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
    return _UICreateScreenUIImage != NULL || UIGetScreenImage != NULL;
}

UIImage *axs_screenocr_capture_screen(void) {
    if (_UICreateScreenUIImage) {
        @try {
            UIImage *image = _UICreateScreenUIImage();
            if (image.CGImage) {
                axs_screenocr_log(@"capture: _UICreateScreenUIImage size=%@",
                                  NSStringFromCGSize(image.size));
                return image;
            }
        } @catch (__unused NSException *exception) {
            axs_screenocr_log(@"capture: _UICreateScreenUIImage threw");
        }
    }

    if (UIGetScreenImage) {
        @try {
            CGImageRef imageRef = UIGetScreenImage();
            if (imageRef) {
                UIImage *image = [UIImage imageWithCGImage:imageRef];
                CGImageRelease(imageRef);
                axs_screenocr_log(@"capture: UIGetScreenImage size=%@",
                                  NSStringFromCGSize(image.size));
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
    return image;
}
