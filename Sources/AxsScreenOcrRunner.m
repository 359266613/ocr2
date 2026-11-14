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

// 只有走兜底路径才需要落盘，进程内识别直接用内存里的 CGImage。
static NSString *axs_screenocr_write_temp_png(UIImage *image) {
    NSString *directory = axs_screenocr_workDirectoryPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *imagePath = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"shot-%.0f.png", [[NSDate date] timeIntervalSince1970] * 1000]];

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

        // 主路径：在本进程直接识别。Vision 的 OCR 模型由 Espresso 加载，
        // 需要 ANE / GPU 后端权限，而这份权限只授予 App 与系统进程；
        // 独立 helper 即使签了 platform-application 也拿不到。
        NSArray<AxsScreenOcrLine *> *lines =
            axs_screenocr_recognize_cgimage(image.CGImage, orientation, &error);
        axs_screenocr_log(@"in-process pass: %lu lines, error=%@",
                          (unsigned long)lines.count,
                          error.localizedDescription ?: @"none");

        // 兜底：进程内失败才落盘交给独立进程，省掉一次多余的 PNG 编码。
        if (lines.count == 0) {
            NSString *imagePath = axs_screenocr_write_temp_png(image);
            if (imagePath) {
                NSError *fallbackError = nil;
                NSArray<AxsScreenOcrLine *> *fallback =
                    axs_screenocr_recognize_image_at_path(imagePath, &fallbackError);
                [[NSFileManager defaultManager] removeItemAtPath:imagePath error:NULL];
                if (fallback.count > 0) {
                    lines = fallback;
                    error = nil;
                } else if (fallbackError && !error) {
                    error = fallbackError;
                }
                axs_screenocr_log(@"helper fallback: %lu lines, error=%@",
                                  (unsigned long)fallback.count,
                                  fallbackError.localizedDescription ?: @"none");
            }
        }

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
            // helper 会把多档分辨率的失败原因串在一起返回，浮层只展示开头，其余进日志。
            if (message.length > 180) {
                message = [[message substringToIndex:180] stringByAppendingString:@"…"];
            }
            [AxsScreenOcrResultController
                axs_screenocr_present_text:[NSString stringWithFormat:
                    @"%@\n\n可尝试：\n· 重新触发一次\n· 详情见 /var/mobile/Library/Logs/AxsScreenOcr.log", message]];
        });
    });
}

@end
