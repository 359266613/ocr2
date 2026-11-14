#import "AxsScreenOcrRunner.h"
#import "AxsScreenOcrCapture.h"
#import "AxsScreenOcrLog.h"
#import "AxsScreenOcrPaths.h"
#import "AxsScreenOcrRecognizer.h"
#import "AxsScreenOcrResultController.h"

static BOOL axsScreenOcrRunning = NO;

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

    NSString *directory = axs_screenocr_workDirectoryPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *imagePath = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"shot-%.0f.png", [[NSDate date] timeIntervalSince1970] * 1000]];

    NSData *png = UIImagePNGRepresentation(image);
    if (!png || ![png writeToFile:imagePath atomically:YES]) {
        axsScreenOcrRunning = NO;
        axs_screenocr_log(@"run aborted: cannot write %@", imagePath);
        [AxsScreenOcrResultController
            axs_screenocr_present_text:@"无法写入临时截图文件，请检查 /var/mobile/Library/Caches 权限。"];
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSArray<AxsScreenOcrLine *> *lines = axs_screenocr_recognize_image_at_path(imagePath, &error);
        [[NSFileManager defaultManager] removeItemAtPath:imagePath error:NULL];

        NSTimeInterval elapsed = -[startedAt timeIntervalSinceNow];
        NSMutableString *text = [NSMutableString string];
        for (AxsScreenOcrLine *line in lines) {
            if (text.length > 0) [text appendString:@"\n"];
            [text appendString:line.text];
        }

        axs_screenocr_log(@"recognize finished: %lu lines, %lu chars, %.0f ms",
                          (unsigned long)lines.count, (unsigned long)text.length, elapsed * 1000.0);

        dispatch_async(dispatch_get_main_queue(), ^{
            axsScreenOcrRunning = NO;
            if (text.length > 0) {
                [AxsScreenOcrResultController axs_screenocr_present_text:text];
                return;
            }
            NSString *message = error.localizedDescription ?: @"未识别到文字";
            [AxsScreenOcrResultController
                axs_screenocr_present_text:[NSString stringWithFormat:@"%@\n\n可尝试：\n· 放大画面后重新触发\n· 确认界面不是纯图片或安全界面", message]];
        });
    });
}

@end
