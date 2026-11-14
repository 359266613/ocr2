#import "AxsScreenOcrVisionDiagnostics.h"
#import "AxsScreenOcrVision.h"
#import "AxsScreenOcrRecognizer.h"
#import "AxsScreenOcrPaths.h"

static BOOL axs_screenocr_diagnosticRunning = NO;

@implementation AxsScreenOcrVisionDiagnostics

+ (void)axs_screenocr_runFromController:(UIViewController *)controller {
    if (axs_screenocr_diagnosticRunning) return;
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Vision 环境对照"
        message:@"将用同一张中英文测试图比较独立工作应用与设置进程，期间会切换应用。设置进程直接加载系统模型，若框架崩溃，设置可能退出；不会在 SpringBoard 内运行 Vision。"
        preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"开始" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [controller dismissViewControllerAnimated:YES completion:^{
            [self axs_screenocr_startFromController:controller];
        }];
    }]];
    [controller presentViewController:confirm animated:YES completion:nil];
}

+ (void)axs_screenocr_startFromController:(UIViewController *)controller {
    if (axs_screenocr_diagnosticRunning) return;
    axs_screenocr_diagnosticRunning = YES;
    NSString *logPath = axs_screenocr_userLibraryPath(@"Logs/AxsScreenOcrVisionDiagnostic.log");
    NSFileManager *manager = NSFileManager.defaultManager;
    [manager createDirectoryAtPath:logPath.stringByDeletingLastPathComponent
      withIntermediateDirectories:YES attributes:nil error:NULL];
    NSError *writeError = nil;
    NSData *header = [[NSString stringWithFormat:@"--- %@\n%@\n", NSDate.date,
        axs_screenocr_vision_environment()] dataUsingEncoding:NSUTF8StringEncoding];
    if (![header writeToFile:logPath options:NSDataWritingAtomic error:&writeError]) {
        axs_screenocr_diagnosticRunning = NO;
        [self axs_screenocr_showResult:writeError.localizedDescription controller:controller];
        return;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!handle) {
        axs_screenocr_diagnosticRunning = NO;
        [self axs_screenocr_showResult:@"无法打开诊断日志。" controller:controller];
        return;
    }
    [handle seekToEndOfFile];
    void (^note)(NSString *) = ^(NSString *message) {
        @try {
            [handle writeData:[[message stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
            // Persist the boundary before entering a possibly crashing framework.
            [handle synchronizeFile];
        } @catch (__unused NSException *exception) {}
    };

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(1179, 850) format:format];
    UIImage *sample = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [UIColor.whiteColor setFill];
        UIRectFill(CGRectMake(0, 0, 1179, 850));
        NSDictionary *attributes = @{NSFontAttributeName: [UIFont systemFontOfSize:54],
                                      NSForegroundColorAttributeName: UIColor.blackColor};
        [@"中文识别测试 简体文字" drawAtPoint:CGPointMake(70, 100) withAttributes:attributes];
        [@"繁體文字 測試結果" drawAtPoint:CGPointMake(70, 240) withAttributes:attributes];
        [@"Apple Vision OCR" drawAtPoint:CGPointMake(70, 380) withAttributes:attributes];
        [@"1234567890" drawAtPoint:CGPointMake(70, 520) withAttributes:attributes];
    }];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"AxsScreenOcrDiagnostic-%@.png", NSUUID.UUID.UUIDString]];
    NSData *png = UIImagePNGRepresentation(sample);
    if (!png || ![png writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        note([NSString stringWithFormat:@"sample write failed: %@", writeError]);
        [handle closeFile];
        axs_screenocr_diagnosticRunning = NO;
        [self axs_screenocr_showResult:@"无法保存诊断图片。" controller:controller];
        return;
    }
    note([NSString stringWithFormat:@"sample=%@ bytes=%lu; UIKit worker and Preferences use identical PNG bytes, split=0",
          path, (unsigned long)png.length]);

    UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"正在对照"
        message:@"工作应用 → 设置进程" preferredStyle:UIAlertControllerStyleAlert];
    [controller presentViewController:progress animated:YES completion:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSString *summary = nil;
            @try {
                note(@"stage=UIKitWorker begin");
                NSError *workerError = nil;
                NSArray<AxsScreenOcrLine *> *workerLines = axs_screenocr_recognize_single_image_at_path(path, &workerError);
                note([NSString stringWithFormat:@"stage=UIKitWorker end success=%d lines=%lu error=%@",
                      workerLines != nil, (unsigned long)workerLines.count,
                      workerError ? axs_screenocr_vision_describe_error(workerError) : @"none"]);
                // Log the synthetic result only; production screenshots are never logged.
                note([NSString stringWithFormat:@"worker sample text=%@", [workerLines valueForKey:@"text"]]);
                CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
                CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
                if (source) CFRelease(source);
                if (!image) {
                    summary = @"诊断图片解码失败，未运行设置进程测试。";
                } else {
                    NSError *preferencesError = nil;
                    NSArray<NSDictionary *> *preferencesLines;
                    note(@"stage=Preferences begin");
                    @try {
                        preferencesLines = axs_screenocr_vision_recognize(image, kCGImagePropertyOrientationUp,
                            NO, note, &preferencesError);
                    } @finally {
                        CGImageRelease(image);
                    }
                    note([NSString stringWithFormat:@"stage=Preferences end success=%d lines=%lu error=%@",
                        preferencesLines != nil, (unsigned long)preferencesLines.count,
                        preferencesError ? axs_screenocr_vision_describe_error(preferencesError) : @"none"]);
                    note([NSString stringWithFormat:@"Preferences sample text=%@", [preferencesLines valueForKey:@"text"]]);
                    if (preferencesLines.count && !workerLines.count) {
                        summary = @"设置进程能识别，独立工作应用未识别出文字。请对照工作应用的启动、接收任务与模型日志。";
                    } else if (!preferencesLines.count && workerLines.count) {
                        summary = @"独立工作应用能识别，设置进程未识别出文字。请对照两侧错误及宿主环境。";
                    } else if (preferencesLines.count && workerLines.count) {
                        summary = @"两个进程均返回文字。还需核对诊断日志中的中英文准确性，再测试实际截图。";
                    } else {
                        summary = @"两个应用进程均未识别出文字。请查看两侧模型错误。";
                    }
                }
                note(summary);
            } @catch (NSException *exception) {
                summary = [NSString stringWithFormat:@"诊断异常：%@", exception.reason ?: exception.name];
                note(summary);
            } @finally {
                [manager removeItemAtPath:path error:NULL];
                [handle closeFile];
            }
            NSString *message = [NSString stringWithFormat:@"%@\n\n日志：%@", summary ?: @"诊断未完成。", logPath];
            dispatch_async(dispatch_get_main_queue(), ^{
                axs_screenocr_diagnosticRunning = NO;
                [progress dismissViewControllerAnimated:YES completion:^{
                    [self axs_screenocr_showResult:message controller:controller];
                }];
            });
        }
    });
}

+ (void)axs_screenocr_showResult:(NSString *)message controller:(UIViewController *)controller {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Vision 对照结果"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

@end
