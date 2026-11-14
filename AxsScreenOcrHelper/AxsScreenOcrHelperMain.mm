#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h>
#import <math.h>
#import <stdio.h>
#import <unistd.h>

// 独立识别进程：由 SpringBoard 内的 dylib 以 posix_spawn 启动。
// 参数 argv[1] 是待识别 PNG 路径，结果以单行 JSON 写到 stdout。
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
    if ([underlying isKindOfClass:[NSError class]]) {
        [text appendFormat:@" · %@", underlying.localizedDescription ?: @""];
    }
    return text;
}

// main 是工具链固定入口名，按约定保留原名。
int main(int argc, char *argv[]) {
    @autoreleasepool {
        // helper 由 SpringBoard（root）posix_spawn，默认继承 uid 0。
        // Vision 依赖的 ANE 缓存目录归 mobile 所有，aned 的 XPC 也会校验调用者身份，
        // root 的裸进程会加载模型失败。降到 mobile 后走正常路径。
        setgid(501);
        setuid(501);

        // NSLog 写 stderr。之前父进程把 stderr 也 dup 到同一条管道，
        // 框架日志就混进了 JSON，导致解析失败。这里直接丢掉，错误信息走 JSON 返回。
        freopen("/dev/null", "w", stderr);

        if (argc < 2) return axs_screenocr_helper_fail(@"missing image path", 2);

        NSString *path = [NSString stringWithUTF8String:argv[1]];
        if (path.length == 0) return axs_screenocr_helper_fail(@"invalid image path", 2);

        NSURL *url = [NSURL fileURLWithPath:path];
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        if (!source) return axs_screenocr_helper_fail(@"cannot open image", 3);

        CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
        if (!image) return axs_screenocr_helper_fail(@"cannot decode image", 4);

        VNImageRequestHandler *handler =
            [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];

        VNRecognizeTextRequest *request = nil;
        NSError *requestError = nil;
        BOOL succeeded = NO;

        @try {
            request = axs_screenocr_helper_request(VNRequestTextRecognitionLevelAccurate);
            succeeded = [handler performRequests:@[ request ] error:&requestError];

            if (!succeeded) {
                // Accurate 失败时降级到 Fast 再试一次，两轮都失败才认定识别失败。
                request = axs_screenocr_helper_request(VNRequestTextRecognitionLevelFast);
                requestError = nil;
                succeeded = [handler performRequests:@[ request ] error:&requestError];
            }
        } @catch (NSException *exception) {
            CGImageRelease(image);
            return axs_screenocr_helper_fail(exception.reason ?: @"recognition crashed", 6);
        }
        CGImageRelease(image);

        if (!succeeded) {
            return axs_screenocr_helper_fail(axs_screenocr_helper_describe(requestError), 5);
        }

        NSMutableArray<NSDictionary *> *lines = [NSMutableArray array];
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

        return axs_screenocr_helper_emit(@{ @"ok": @YES, @"lines": lines });
    }
}
