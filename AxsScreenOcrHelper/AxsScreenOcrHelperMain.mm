#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h>
#import <math.h>
#import <stdio.h>
#import <unistd.h>

// 独立识别进程：由 SpringBoard 内的 dylib 以 posix_spawn 启动。
// 参数 argv[1] 是待识别 PNG 路径，结果以单行 JSON 写到 stdout。

static NSString * const AxsScreenOcrHelperLogDirectory = @"/var/mobile/Library/Logs";
static NSString * const AxsScreenOcrHelperLogFile = @"/var/mobile/Library/Logs/AxsScreenOcrHelper.log";
static const unsigned long long AxsScreenOcrHelperLogLimit = 256 * 1024;

// 屏幕原图长边 2556。Vision 内部会为整幅画面申请一条 420f 的 IOSurface 像素缓冲，
// 尺寸越大越容易被系统拒绝；缩到 2048 以内对中文识别几乎没有影响，但显著降低失败率。
static const CGFloat AxsScreenOcrHelperMaxEdge = 2048.0;

static void axs_screenocr_helper_note(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stderr, "%s\n", message.UTF8String ?: "");
    fflush(stderr);
}

// 把 stderr 落到文件。此前为了不污染 stdout 管道，直接丢进 /dev/null，
// 结果框架报错只剩最后一句话，看不到上下文，排查成本很高。
static void axs_screenocr_helper_open_log(void) {
    NSFileManager *manager = [NSFileManager defaultManager];
    [manager createDirectoryAtPath:AxsScreenOcrHelperLogDirectory
       withIntermediateDirectories:YES attributes:nil error:NULL];

    NSDictionary *attributes = [manager attributesOfItemAtPath:AxsScreenOcrHelperLogFile error:NULL];
    if ([attributes[NSFileSize] unsignedLongLongValue] > AxsScreenOcrHelperLogLimit) {
        [manager removeItemAtPath:AxsScreenOcrHelperLogFile error:NULL];
    }
    (void)freopen(AxsScreenOcrHelperLogFile.fileSystemRepresentation, "a", stderr);
}

static int axs_screenocr_helper_emit(NSDictionary *payload) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (!data) {
        fputs("{\"ok\":false,\"error\":\"json encode failed\"}\n", stdout);
        fflush(stdout);
        return 1;
    }
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    return 0;
}

static int axs_screenocr_helper_fail(NSString *message, int code) {
    axs_screenocr_helper_note(@"fail(%d): %@", code, message);
    axs_screenocr_helper_emit(@{ @"ok": @NO, @"error": message ?: @"unknown error" });
    return code;
}

// 统一构造识别请求。越狱 helper 没有 ANE entitlement，Espresso 走 GPU/ANE 后端时
// 会报 "Error loading network -5, -1"，强制 CPU 后端后可以稳定出结果。
static VNRecognizeTextRequest *axs_screenocr_helper_request(VNRequestTextRecognitionLevel level) {
    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
    request.recognitionLevel = level;
    request.usesLanguageCorrection = YES;
    request.recognitionLanguages = @[ @"zh-Hans", @"zh-Hant", @"en-US" ];
    if (@available(iOS 16.0, *)) {
        // 让系统按画面内容自动判断语种，混合排版更稳。
        request.automaticallyDetectsLanguage = YES;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    request.usesCPUOnly = YES;
#pragma clang diagnostic pop
    return request;
}

static NSString *axs_screenocr_helper_describe(NSError *error) {
    if (!error) return @"recognition failed";
    NSMutableString *text = [NSMutableString stringWithString:error.localizedDescription ?: @"recognition failed"];
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if ([underlying isKindOfClass:[NSError class]] && underlying.localizedDescription.length > 0) {
        [text appendFormat:@" · %@", underlying.localizedDescription];
    }
    return text;
}

// 等比缩放。返回 +1 引用，调用方负责 CGImageRelease。
static CGImageRef axs_screenocr_helper_scaled_copy(CGImageRef image, CGFloat factor) {
    if (factor >= 0.999) return CGImageRetain(image);

    size_t width = (size_t)llround(CGImageGetWidth(image) * factor);
    size_t height = (size_t)llround(CGImageGetHeight(image) * factor);
    if (width < 64 || height < 64) return CGImageRetain(image);

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    if (!space) return CGImageRetain(image);
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!context) return CGImageRetain(image);

    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, (CGFloat)width, (CGFloat)height), image);
    CGImageRef scaled = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return scaled ?: CGImageRetain(image);
}

// 跑一轮识别。返回 YES 表示请求本身跑通了（lines 可能为空，即画面无文字）；
// 返回 NO 表示框架层失败（例如申请不到像素缓冲），原因写进 outError。
static BOOL axs_screenocr_helper_perform(CGImageRef image,
                                         VNRequestTextRecognitionLevel level,
                                         NSMutableArray<NSDictionary *> *lines,
                                         NSError **outError) {
    NSError *error = nil;
    BOOL succeeded = NO;
    VNRecognizeTextRequest *request = nil;

    @try {
        VNImageRequestHandler *handler =
            [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
        request = axs_screenocr_helper_request(level);
        succeeded = [handler performRequests:@[ request ] error:&error];
    } @catch (NSException *exception) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"com.axs.screenocr.helper" code:1
                                        userInfo:@{ NSLocalizedDescriptionKey:
                                            exception.reason ?: @"recognition crashed" }];
        }
        axs_screenocr_helper_note(@"exception: %@", exception.reason ?: @"(nil)");
        return NO;
    }

    if (!succeeded) {
        if (outError) *outError = error;
        axs_screenocr_helper_note(@"level=%ld failed: %@",
                                  (long)level, axs_screenocr_helper_describe(error));
        return NO;
    }

    for (VNRecognizedTextObservation *observation in request.results) {
        VNRecognizedText *candidate = [[observation topCandidates:1] firstObject];
        if (candidate.string.length == 0) continue;
        CGRect box = observation.boundingBox;
        [lines addObject:@{
            @"text": candidate.string,
            @"x": @(box.origin.x),
            @"y": @(box.origin.y),
            @"w": @(box.size.width),
            @"h": @(box.size.height),
        }];
    }
    return YES;
}

// 诊断用：拿一张 128x128 的纯白图跑一次最小识别。
// 小图能过说明 Vision 后端可用、问题只在缓冲尺寸；小图也过不去就是权限层面的事。
static void axs_screenocr_helper_selftest(void) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    if (!space) return;
    CGContextRef context = CGBitmapContextCreate(NULL, 128, 128, 8, 0, space,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!context) {
        axs_screenocr_helper_note(@"selftest: cannot create context");
        return;
    }
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, 128, 128));
    CGImageRef probe = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (!probe) return;

    NSMutableArray<NSDictionary *> *lines = [NSMutableArray array];
    NSError *error = nil;
    BOOL performed = axs_screenocr_helper_perform(probe,
                                                  VNRequestTextRecognitionLevelFast,
                                                  lines, &error);
    axs_screenocr_helper_note(@"selftest 128x128 -> %@", performed
                              ? @"vision usable (buffer size is the problem)"
                              : axs_screenocr_helper_describe(error));
    CGImageRelease(probe);
}

// main 是工具链固定入口名，按约定保留原名。
int main(int argc, char *argv[]) {
    @autoreleasepool {
        // helper 由 SpringBoard（root）posix_spawn，默认继承 uid 0。
        // Vision 依赖的 ANE 缓存目录归 mobile 所有，aned 的 XPC 也会校验调用者身份，
        // root 的裸进程会加载模型失败。降到 mobile 后走正常路径。
        setgid(501);
        setuid(501);

        axs_screenocr_helper_open_log();
        axs_screenocr_helper_note(@"--- helper start pid=%d", (int)getpid());

        if (argc < 2) return axs_screenocr_helper_fail(@"missing image path", 2);

        NSString *path = [NSString stringWithUTF8String:argv[1]];
        if (path.length == 0) return axs_screenocr_helper_fail(@"invalid image path", 2);

        NSURL *url = [NSURL fileURLWithPath:path];
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        if (!source) return axs_screenocr_helper_fail(@"cannot open image", 3);

        CGImageRef original = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
        if (!original) return axs_screenocr_helper_fail(@"cannot decode image", 4);

        size_t pixelWidth = CGImageGetWidth(original);
        size_t pixelHeight = CGImageGetHeight(original);
        CGFloat longest = (CGFloat)MAX(pixelWidth, pixelHeight);
        CGFloat baseFactor = (longest > AxsScreenOcrHelperMaxEdge) ? (AxsScreenOcrHelperMaxEdge / longest) : 1.0;
        axs_screenocr_helper_note(@"image %zux%zu, base factor %.3f", pixelWidth, pixelHeight, baseFactor);

        // 从原始分辨率开始逐级缩小。CVPixelBuffer 申请失败多数出现在大尺寸上，
        // 缩一档往往就能过；识别精度对屏幕文字而言几无损失。
        CGFloat factors[] = { 1.0, 0.75, 0.55 };
        NSMutableString *trail = [NSMutableString string];
        NSMutableArray<NSDictionary *> *lines = [NSMutableArray array];
        BOOL detectedNothing = NO;
        BOOL selfTested = NO;

        for (size_t index = 0; index < sizeof(factors) / sizeof(factors[0]); index++) {
            CGFloat factor = baseFactor * factors[index];
            CGImageRef scaled = axs_screenocr_helper_scaled_copy(original, factor);

            NSError *error = nil;
            [lines removeAllObjects];
            BOOL performed = axs_screenocr_helper_perform(scaled,
                                                          VNRequestTextRecognitionLevelAccurate,
                                                          lines, &error);
            if (!performed) {
                // Accurate 失败时降级到 Fast 再试一次，两轮都失败才换下一档分辨率。
                [lines removeAllObjects];
                performed = axs_screenocr_helper_perform(scaled,
                                                         VNRequestTextRecognitionLevelFast,
                                                         lines, &error);
            }

            axs_screenocr_helper_note(@"attempt %.3f at %zux%zu -> %@ (lines=%lu)", factor,
                                      CGImageGetWidth(scaled), CGImageGetHeight(scaled),
                                      performed ? @"ok" : @"failed",
                                      (unsigned long)lines.count);
            CGImageRelease(scaled);

            if (!performed && !selfTested) {
                selfTested = YES;
                axs_screenocr_helper_selftest();
            }

            if (performed) {
                // 请求跑通就停下来：有字已经拿到，没字说明画面本身没有可识别文字，
                // 再缩图重试也不会有结果。
                if (lines.count == 0) detectedNothing = YES;
                break;
            }
            [trail appendFormat:@"%.0f%% 尺寸失败：%@；", factor * 100.0,
                                axs_screenocr_helper_describe(error)];
        }

        CGImageRelease(original);

        if (lines.count == 0) {
            if (detectedNothing) {
                axs_screenocr_helper_note(@"no text in image");
                return axs_screenocr_helper_fail(@"画面中没有识别到文字", 7);
            }
            if (trail.length == 0) return axs_screenocr_helper_fail(@"图片来源异常", 7);
            return axs_screenocr_helper_fail(trail, 8);
        }

        // Vision 返回顺序不保证阅读顺序，按行（y 降序）再按列（x 升序）重排。
        [lines sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            double leftY = [left[@"y"] doubleValue];
            double rightY = [right[@"y"] doubleValue];
            if (fabs(leftY - rightY) > 0.01) {
                return leftY > rightY ? NSOrderedAscending : NSOrderedDescending;
            }
            double leftX = [left[@"x"] doubleValue];
            double rightX = [right[@"x"] doubleValue];
            if (leftX == rightX) return NSOrderedSame;
            return leftX < rightX ? NSOrderedAscending : NSOrderedDescending;
        }];

        if (trail.length > 0) {
            axs_screenocr_helper_note(@"recovered after: %@", trail);
        }
        axs_screenocr_helper_note(@"done: %lu lines", (unsigned long)lines.count);
        return axs_screenocr_helper_emit(@{ @"ok": @YES, @"lines": lines });
    }
}
