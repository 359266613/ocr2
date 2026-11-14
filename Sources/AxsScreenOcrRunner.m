#import "AxsScreenOcrRunner.h"
#import "AxsScreenOcrCapture.h"
#import "AxsScreenOcrLog.h"
#import "AxsScreenOcrPaths.h"
#import "AxsScreenOcrRecognizer.h"
#import "AxsScreenOcrResultController.h"

static BOOL axsScreenOcrRunning = NO;

static CGImagePropertyOrientation axs_screenocr_orientation(UIImageOrientation orientation) {
    switch (orientation) {
        case UIImageOrientationDown: return kCGImagePropertyOrientationDown;
        case UIImageOrientationLeft: return kCGImagePropertyOrientationLeft;
        case UIImageOrientationRight: return kCGImagePropertyOrientationRight;
        case UIImageOrientationUpMirrored: return kCGImagePropertyOrientationUpMirrored;
        case UIImageOrientationDownMirrored: return kCGImagePropertyOrientationDownMirrored;
        case UIImageOrientationLeftMirrored: return kCGImagePropertyOrientationLeftMirrored;
        case UIImageOrientationRightMirrored: return kCGImagePropertyOrientationRightMirrored;
        case UIImageOrientationUp:
        default:
            return kCGImagePropertyOrientationUp;
    }
}

static NSString *axs_screenocr_write_temp_png(UIImage *image) {
    NSString *directory = axs_screenocr_workDirectoryPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *imagePath = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"shot-%@.png", NSUUID.UUID.UUIDString]];

    NSData *png = UIImagePNGRepresentation(image);
    if (!png || ![png writeToFile:imagePath atomically:YES]) return nil;
    return imagePath;
}

@implementation AxsScreenOcrRunner

+ (void)axs_screenocr_run {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self axs_screenocr_run];
        });
        return;
    }
    if (axsScreenOcrRunning) {
        axs_screenocr_log(@"run ignored: previous recognition still in progress");
        return;
    }
    if ([AxsScreenOcrResultController axs_screenocr_is_presenting]) {
        axs_screenocr_log(@"run ignored: result overlay already visible");
        return;
    }

    axsScreenOcrRunning = YES;
    NSDate *startedAt = [NSDate date];

    UIImage *image = axs_screenocr_capture_screen();
    if (!image.CGImage) {
        axsScreenOcrRunning = NO;
        axs_screenocr_log(@"run aborted: capture failed");
        [AxsScreenOcrResultController
            axs_screenocr_present_text:@"截图失败。\n\n当前界面可能受系统保护（如视频 DRM、银行类安全界面），无法抓取像素。"];
        return;
    }

    CGImagePropertyOrientation orientation = axs_screenocr_orientation(image.imageOrientation);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;

        NSArray<AxsScreenOcrLine *> *lines = nil;
        NSString *imagePath = axs_screenocr_write_temp_png(image);
        if (imagePath) {
            @try {
                lines = axs_screenocr_recognize_image_at_path(imagePath, orientation, &error);
            } @catch (NSException *exception) {
                axs_screenocr_log(@"helper invocation exception: %@", exception.reason ?: @"unknown");
                error = [NSError errorWithDomain:@"com.axs.screenocr" code:34
                    userInfo:@{NSLocalizedDescriptionKey: @"识别组件调用失败"}];
            } @finally {
                NSError *removeError = nil;
                if (![[NSFileManager defaultManager] removeItemAtPath:imagePath error:&removeError]) {
                    axs_screenocr_log(@"temporary screenshot cleanup failed: %@", removeError.localizedDescription);
                }
            }
        } else {
            error = [NSError errorWithDomain:@"com.axs.screenocr" code:33
                userInfo:@{NSLocalizedDescriptionKey: @"无法创建临时截图，请检查存储空间和权限"}];
        }
        axs_screenocr_log(@"helper pass: %lu lines, error=%@",
                          (unsigned long)lines.count, error.localizedDescription ?: @"none");

        NSMutableString *text = [NSMutableString string];
        for (AxsScreenOcrLine *line in lines) {
            if (text.length > 0) [text appendString:@"\n"];
            [text appendString:line.text];
        }

        NSTimeInterval elapsed = -[startedAt timeIntervalSinceNow];
        axs_screenocr_log(@"recognize finished: %lu lines, %lu chars, %.0f ms",
                          (unsigned long)lines.count, (unsigned long)text.length, elapsed * 1000.0);

        dispatch_async(dispatch_get_main_queue(), ^{
            axsScreenOcrRunning = NO;
            if (text.length > 0) {
                [AxsScreenOcrResultController axs_screenocr_present_text:text];
                return;
            }
            NSString *message = error.localizedDescription ?: @"未识别到文字";
            // Full framework error details stay in the log, not the compact overlay.
            if (message.length > 180) {
                message = [[message substringToIndex:180] stringByAppendingString:@"…"];
            }
            [AxsScreenOcrResultController
                axs_screenocr_present_text:[NSString stringWithFormat:
                    @"%@\n\n请先在插件设置运行「Vision 环境对照测试」。\n详情见 /var/mobile/Library/Logs/AxsScreenOcr.log", message]];
        });
    });
}

@end
