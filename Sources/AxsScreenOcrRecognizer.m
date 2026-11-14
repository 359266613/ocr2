#import "AxsScreenOcrRecognizer.h"
#import "AxsScreenOcrAppHost.h"
#import "AxsScreenOcrLog.h"
#import "AxsScreenOcrPaths.h"
#import "AxsScreenOcrIPC.h"
#import <UIKit/UIKit.h>
#import <math.h>
#import <unistd.h>

@implementation AxsScreenOcrLine
@end

static NSError *axs_screenocr_transport_error(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.axs.screenocr.transport" code:code
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSArray<AxsScreenOcrLine *> *axs_screenocr_worker_result(NSDictionary *payload,
    NSString *identifier, NSError **error) {
    if (![payload[@"id"] isEqual:identifier] || ![payload[@"version"] isEqual:@1] ||
        ![payload[@"ok"] isKindOfClass:NSNumber.class]) {
        if (error) *error = axs_screenocr_transport_error(14, @"工作应用返回了无效任务结果");
        return nil;
    }
    if (![payload[@"ok"] boolValue]) {
        NSDictionary *details = [payload[@"error"] isKindOfClass:NSDictionary.class] ? payload[@"error"] : @{};
        NSString *domain = [details[@"domain"] isKindOfClass:NSString.class] ? details[@"domain"] : @"com.axs.screenocr.worker";
        NSString *message = [details[@"message"] isKindOfClass:NSString.class] ? details[@"message"] : @"工作应用识别失败";
        NSInteger code = [details[@"code"] isKindOfClass:NSNumber.class] ? [details[@"code"] integerValue] : 1;
        if (error) *error = [NSError errorWithDomain:domain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
        axs_screenocr_log(@"worker reported error: %@/%ld %@", domain, (long)code, message);
        return nil;
    }
    if (![payload[@"lines"] isKindOfClass:NSArray.class]) {
        if (error) *error = axs_screenocr_transport_error(14, @"工作应用结果缺少文字数组");
        return nil;
    }
    NSMutableArray<AxsScreenOcrLine *> *lines = [NSMutableArray array];
    for (id value in payload[@"lines"]) {
        if (![value isKindOfClass:NSDictionary.class]) {
            if (error) *error = axs_screenocr_transport_error(14, @"文字行格式不正确");
            return nil;
        }
        NSDictionary *item = value;
        if (![item[@"text"] isKindOfClass:NSString.class]) {
            if (error) *error = axs_screenocr_transport_error(14, @"文字行缺少正文");
            return nil;
        }
        for (NSString *key in @[@"x", @"y", @"w", @"h"]) {
            if (![item[key] isKindOfClass:NSNumber.class] || !isfinite([item[key] doubleValue])) {
                if (error) *error = axs_screenocr_transport_error(14, @"文字坐标不正确");
                return nil;
            }
        }
        if (![item[@"text"] length]) continue;
        AxsScreenOcrLine *line = [AxsScreenOcrLine new];
        line.text = item[@"text"];
        line.box = CGRectMake([item[@"x"] doubleValue], [item[@"y"] doubleValue],
                              [item[@"w"] doubleValue], [item[@"h"] doubleValue]);
        [lines addObject:line];
    }
    return lines;
}

static NSArray<AxsScreenOcrLine *> *axs_screenocr_run_worker(NSString *imagePath,
    CGImagePropertyOrientation orientation, BOOL split, NSError **error) {
    if (error) *error = nil;
    if (NSThread.isMainThread) {
        if (error) *error = axs_screenocr_transport_error(10, @"识别等待不能阻塞主线程");
        return nil;
    }
    NSString *app = axs_screenocr_resourcePath(@"/Applications/AxsScreenOcrWorker.app");
    if (![NSFileManager.defaultManager isExecutableFileAtPath:
          [app stringByAppendingPathComponent:@"AxsScreenOcrWorker"]]) {
        if (error) *error = axs_screenocr_transport_error(11, @"OCR 工作应用缺失，请重新安装插件");
        return nil;
    }
    NSString *identifier = axs_screenocr_job_create(imagePath, orientation, split, error);
    if (!identifier) return nil;
    NSString *directory = axs_screenocr_job_directory(identifier);
    NSString *replyPath = [directory stringByAppendingPathComponent:@"response.json"];
    NSString *statusPath = [directory stringByAppendingPathComponent:@"status.json"];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://job/%@", AxsScreenOcrWorkerURLScheme, identifier]];
    NSObject *lock = [NSObject new];
    __block BOOL cancelled = NO, launchFinished = NO, launchAccepted = NO;
    __block NSString *previousApplication = nil;
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + AxsScreenOcrJobTimeout;
    axs_screenocr_log(@"worker submit id=%@ split=%d transport=UIKit+JSON", identifier, split);

    @try {
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized (lock) {
                if (cancelled || NSProcessInfo.processInfo.systemUptime >= deadline) return;
            }
            @try {
                axs_screenocr_log(@"worker foreground snapshot begin id=%@", identifier);
                NSString *caller = NSBundle.mainBundle.bundleIdentifier;
                NSString *front = [caller isEqualToString:@"com.apple.springboard"]
                    ? axs_screenocr_front_application() : caller;
                axs_screenocr_log(@"worker foreground snapshot end id=%@ previous=%@", identifier, front ?: @"none");
                @synchronized (lock) {
                    if (cancelled || NSProcessInfo.processInfo.systemUptime >= deadline) return;
                    previousApplication = front;
                }
                // Framework calls and their callbacks must not execute while holding the state lock.
                axs_screenocr_log(@"worker openURL begin id=%@", identifier);
                [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL accepted) {
                    @synchronized (lock) {
                        if (cancelled) return;
                        launchFinished = YES;
                        launchAccepted = accepted;
                    }
                    axs_screenocr_log(@"worker launch id=%@ accepted=%d", identifier, accepted);
                }];
                axs_screenocr_log(@"worker openURL returned id=%@", identifier);
            } @catch (NSException *exception) {
                @synchronized (lock) {
                    launchFinished = YES;
                    launchAccepted = NO;
                }
                axs_screenocr_log(@"worker launch exception: %@", exception.reason ?: exception.name);
            }
        });
        BOOL acknowledged = NO;
        while (NSProcessInfo.processInfo.systemUptime < deadline) {
            if ([NSFileManager.defaultManager fileExistsAtPath:replyPath]) {
                NSDictionary *payload = axs_screenocr_ipc_read(replyPath, error);
                if (!payload) return nil;
                NSArray<AxsScreenOcrLine *> *lines = axs_screenocr_worker_result(payload, identifier, error);
                axs_screenocr_log(@"worker reply id=%@ lines=%lu success=%d", identifier,
                                  (unsigned long)lines.count, lines != nil);
                return lines;
            }
            @synchronized (lock) {
                if (launchFinished && !launchAccepted) {
                    if (error) *error = axs_screenocr_transport_error(12,
                        @"系统未能打开 OCR 工作应用，请重新安装插件并确认桌面上有「全屏OCR工作器」");
                    return nil;
                }
            }
            if (!acknowledged && [NSFileManager.defaultManager fileExistsAtPath:statusPath]) {
                NSDictionary *status = axs_screenocr_ipc_read(statusPath, NULL);
                acknowledged = [status[@"id"] isEqual:identifier];
                if (acknowledged) axs_screenocr_log(@"worker acknowledged id=%@ pid=%@", identifier, status[@"pid"]);
            }
            usleep(100000);
        }
        if (error) *error = axs_screenocr_transport_error(13, acknowledged
            ? @"OCR 工作应用处理超时或异常退出，请查看 AxsScreenOcrWorker.log 和工作应用崩溃报告"
            : @"OCR 工作应用未接收任务，请先打开桌面上的「全屏OCR工作器」，再重新触发");
        axs_screenocr_log(@"worker timeout id=%@ acknowledged=%d", identifier, acknowledged);
        return nil;
    } @finally {
        NSString *restore;
        @synchronized (lock) {
            cancelled = YES;
            restore = previousApplication;
        }
        axs_screenocr_job_remove(identifier);
        dispatch_async(dispatch_get_main_queue(), ^{
            axs_screenocr_restore_application(restore);
        });
    }
}

NSArray<AxsScreenOcrLine *> *axs_screenocr_recognize_image_at_path(NSString *imagePath,
    CGImagePropertyOrientation orientation, NSError **error) {
    return axs_screenocr_run_worker(imagePath, orientation, YES, error);
}

NSArray<AxsScreenOcrLine *> *axs_screenocr_recognize_single_image_at_path(NSString *imagePath, NSError **error) {
    return axs_screenocr_run_worker(imagePath, kCGImagePropertyOrientationUp, NO, error);
}
