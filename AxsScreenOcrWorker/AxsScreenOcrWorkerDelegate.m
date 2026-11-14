#import "AxsScreenOcrWorkerDelegate.h"
#import "AxsScreenOcrIPC.h"
#import "AxsScreenOcrVision.h"
#import <unistd.h>

@interface AxsScreenOcrWorkerJob : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic) UIBackgroundTaskIdentifier backgroundTask;
@property (nonatomic) BOOL finished;
@end
@implementation AxsScreenOcrWorkerJob
@end

@interface AxsScreenOcrWorkerDelegate ()
@property (nonatomic, strong) NSMutableArray<NSString *> *axs_screenocr_pending;
@property (nonatomic, strong) AxsScreenOcrWorkerJob *axs_screenocr_current;
@property (nonatomic, strong) UILabel *axs_screenocr_status;
@property (nonatomic, strong) UIActivityIndicatorView *axs_screenocr_spinner;
@property (nonatomic, strong) dispatch_queue_t axs_screenocr_queue;
@end

static NSDictionary *axs_screenocr_worker_failure(NSString *identifier, NSError *error) {
    return @{@"version": @1, @"id": identifier, @"ok": @NO,
             @"error": @{@"domain": error.domain ?: @"com.axs.screenocr.worker",
                         @"code": @(error.code), @"message": error.localizedDescription ?: @"工作应用识别失败"}};
}

static NSError *axs_screenocr_worker_error(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.axs.screenocr.worker" code:code
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation AxsScreenOcrWorkerDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.axs_screenocr_pending = [NSMutableArray array];
    self.axs_screenocr_queue = dispatch_queue_create("com.axs.screenocr.worker.vision", DISPATCH_QUEUE_SERIAL);
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = controller;

    UIImageView *symbol = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"doc.text.viewfinder"]];
    symbol.tintColor = UIColor.systemTealColor;
    symbol.contentMode = UIViewContentModeScaleAspectFit;
    UILabel *title = [UILabel new];
    title.text = @"全屏OCR";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.textAlignment = NSTextAlignmentCenter;
    self.axs_screenocr_status = [UILabel new];
    self.axs_screenocr_status.text = @"等待任务";
    self.axs_screenocr_status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.axs_screenocr_status.textColor = UIColor.secondaryLabelColor;
    self.axs_screenocr_status.textAlignment = NSTextAlignmentCenter;
    self.axs_screenocr_status.numberOfLines = 0;
    self.axs_screenocr_spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.axs_screenocr_spinner.hidesWhenStopped = YES;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
        @[symbol, title, self.axs_screenocr_status, self.axs_screenocr_spinner]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.trailingAnchor constant:-24],
        [stack.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor],
        [symbol.heightAnchor constraintEqualToConstant:56],
        [symbol.widthAnchor constraintEqualToConstant:56],
        [self.axs_screenocr_status.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    ]];
    [self.window makeKeyAndVisible];
    axs_screenocr_worker_note([@"UIApplication didFinishLaunching: " stringByAppendingString:axs_screenocr_vision_environment()]);
    dispatch_async(self.axs_screenocr_queue, ^{ axs_screenocr_jobs_prune(); });
    NSURL *url = options[UIApplicationLaunchOptionsURLKey];
    if (url) [self axs_screenocr_enqueueURL:url];
    return YES;
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary *)options {
    return [self axs_screenocr_enqueueURL:url];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    axs_screenocr_worker_note(@"UIApplication active");
    [self axs_screenocr_startNext];
}

- (BOOL)axs_screenocr_enqueueURL:(NSURL *)url {
    if (![url.scheme.lowercaseString isEqualToString:AxsScreenOcrWorkerURLScheme] ||
        ![url.host isEqualToString:@"job"] || url.pathComponents.count != 2 ||
        url.query.length || url.fragment.length || url.user.length || url.password.length || url.port) return NO;
    NSString *identifier = url.lastPathComponent;
    NSString *directory = axs_screenocr_job_directory(identifier);
    if (!directory) return NO;
    if ([identifier isEqual:self.axs_screenocr_current.identifier] || [self.axs_screenocr_pending containsObject:identifier]) return YES;
    if ([NSFileManager.defaultManager fileExistsAtPath:[directory stringByAppendingPathComponent:@"response.json"]]) return YES;
    if (self.axs_screenocr_pending.count >= 4) {
        axs_screenocr_worker_note(@"request rejected: queue full");
        NSError *error = nil;
        if (axs_screenocr_job_request(identifier, &error)) {
            axs_screenocr_ipc_write(axs_screenocr_worker_failure(identifier,
                axs_screenocr_worker_error(27, @"工作应用任务过多，请稍后重试")),
                [directory stringByAppendingPathComponent:@"response.json"], NULL);
        }
        return YES;
    }
    [self.axs_screenocr_pending addObject:identifier];
    axs_screenocr_worker_note([NSString stringWithFormat:@"request queued id=%@", identifier]);
    [self axs_screenocr_startNext];
    return YES;
}

- (void)axs_screenocr_startNext {
    UIApplication *application = UIApplication.sharedApplication;
    if (self.axs_screenocr_current || !self.axs_screenocr_pending.count ||
        application.applicationState != UIApplicationStateActive) return;
    AxsScreenOcrWorkerJob *job = [AxsScreenOcrWorkerJob new];
    job.identifier = self.axs_screenocr_pending.firstObject;
    job.backgroundTask = UIBackgroundTaskInvalid;
    [self.axs_screenocr_pending removeObjectAtIndex:0];
    self.axs_screenocr_current = job;
    self.axs_screenocr_status.text = @"正在识别";
    [self.axs_screenocr_spinner startAnimating];
    __weak typeof(self) weakSelf = self;
    job.backgroundTask = [application beginBackgroundTaskWithName:@"AxsScreenOcrVision"
        expirationHandler:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf axs_screenocr_finishJob:job payload:axs_screenocr_worker_failure(job.identifier,
                    axs_screenocr_worker_error(20, @"系统结束了工作应用的后台执行时间"))];
            });
        }];
    dispatch_async(self.axs_screenocr_queue, ^{
        @autoreleasepool {
            NSDictionary *payload;
            @try {
                payload = [self axs_screenocr_processJob:job.identifier];
            } @catch (NSException *exception) {
                payload = axs_screenocr_worker_failure(job.identifier,
                    axs_screenocr_worker_error(21, exception.reason ?: exception.name));
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [self axs_screenocr_finishJob:job payload:payload];
            });
        }
    });
}

- (NSDictionary *)axs_screenocr_processJob:(NSString *)identifier {
    NSError *error = nil;
    NSDictionary *request = axs_screenocr_job_request(identifier, &error);
    if (!request) return axs_screenocr_worker_failure(identifier, error);
    NSString *directory = axs_screenocr_job_directory(identifier);
    NSString *inputPath = [directory stringByAppendingPathComponent:@"input.png"];
    NSDictionary *status = @{@"version": @1, @"id": identifier, @"pid": @(getpid()),
                              @"bundle": NSBundle.mainBundle.bundleIdentifier ?: @"none", @"stage": @"received"};
    if (!axs_screenocr_ipc_write(status, [directory stringByAppendingPathComponent:@"status.json"], &error)) {
        return axs_screenocr_worker_failure(identifier, error);
    }
    axs_screenocr_worker_note([NSString stringWithFormat:@"request begin id=%@ split=%@", identifier, request[@"split"]]);
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:inputPath error:&error];
    if (!attributes) return axs_screenocr_worker_failure(identifier, error);
    if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular] ||
        [attributes[NSFileOwnerAccountID] unsignedIntValue] != 501 ||
        [attributes[NSFileSize] unsignedLongLongValue] > AxsScreenOcrIPCMaxImageBytes) {
        return axs_screenocr_worker_failure(identifier, axs_screenocr_worker_error(22, @"截图文件类型、所有者或大小不正确"));
    }
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:inputPath], NULL);
    if (!source) return axs_screenocr_worker_failure(identifier, axs_screenocr_worker_error(23, @"无法打开截图"));
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    double width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
    double height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
    if (!(width > 0 && height > 0 && width <= 32768 && height <= 32768 && width * height <= 32 * 1024 * 1024)) {
        CFRelease(source);
        return axs_screenocr_worker_failure(identifier, axs_screenocr_worker_error(24, @"截图像素尺寸无效或过大"));
    }
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) return axs_screenocr_worker_failure(identifier, axs_screenocr_worker_error(25, @"无法解码截图"));
    // The image provider retains what it needs; do not leave screenshot files
    // waiting on the model computation or the caller's process lifetime.
    [NSFileManager.defaultManager removeItemAtPath:inputPath error:NULL];
    NSArray<NSDictionary *> *lines;
    @try {
        lines = axs_screenocr_vision_recognize(image,
            (CGImagePropertyOrientation)[request[@"orientation"] integerValue], [request[@"split"] boolValue],
            ^(NSString *message) { axs_screenocr_worker_note(message); }, &error);
    } @finally {
        CGImageRelease(image);
    }
    if ([request[@"deadline"] doubleValue] <= NSDate.date.timeIntervalSince1970) {
        return axs_screenocr_worker_failure(identifier, axs_screenocr_worker_error(26, @"识别结果已超时"));
    }
    if (!lines) {
        axs_screenocr_worker_note(axs_screenocr_vision_describe_error(error));
        return axs_screenocr_worker_failure(identifier, error);
    }
    return @{@"version": @1, @"id": identifier, @"ok": @YES, @"lines": lines, @"backend": @"UIKit"};
}

- (void)axs_screenocr_finishJob:(AxsScreenOcrWorkerJob *)job payload:(NSDictionary *)payload {
    if (job.finished) return;
    job.finished = YES;
    NSString *directory = axs_screenocr_job_directory(job.identifier);
    NSFileManager *manager = NSFileManager.defaultManager;
    [manager removeItemAtPath:[directory stringByAppendingPathComponent:@"input.png"] error:NULL];
    NSError *error = nil;
    if ([manager fileExistsAtPath:[directory stringByAppendingPathComponent:@"request.json"]]) {
        NSString *replyPath = [directory stringByAppendingPathComponent:@"response.json"];
        if (!axs_screenocr_ipc_write(payload, replyPath, &error)) {
            // Oversize success results become a small, explicit error response.
            axs_screenocr_worker_note([NSString stringWithFormat:@"reply write failed: %@", error]);
            axs_screenocr_ipc_write(axs_screenocr_worker_failure(job.identifier, error), replyPath, NULL);
        }
    }
    BOOL success = [payload[@"ok"] boolValue] && !error;
    axs_screenocr_worker_note([NSString stringWithFormat:@"request end id=%@ success=%d lines=%lu",
        job.identifier, success, (unsigned long)[payload[@"lines"] count]]);
    if (self.axs_screenocr_current == job) {
        [self.axs_screenocr_spinner stopAnimating];
        self.axs_screenocr_status.text = success
            ? [NSString stringWithFormat:@"已完成 %lu 行", (unsigned long)[payload[@"lines"] count]]
            : @"识别失败";
        self.axs_screenocr_current = nil;
    }
    if (job.backgroundTask != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:job.backgroundTask];
        job.backgroundTask = UIBackgroundTaskInvalid;
    }
    // Covers a caller that died after handing off the job.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_SEC), self.axs_screenocr_queue, ^{
        axs_screenocr_job_remove(job.identifier);
    });
    [self axs_screenocr_startNext];
}

@end
