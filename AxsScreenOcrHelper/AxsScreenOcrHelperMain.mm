#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h>
#import <math.h>
#import <stdio.h>

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

// main 是工具链固定入口名，按约定保留原名。
int main(int argc, char *argv[]) {
    @autoreleasepool {
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
        VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        request.usesLanguageCorrection = YES;
        request.recognitionLanguages = @[ @"zh-Hans", @"zh-Hant", @"en-US" ];
        if (@available(iOS 16.0, *)) {
            // 让系统按画面内容自动判断语种，混合排版更稳。
            request.automaticallyDetectsLanguage = YES;
        }

        NSError *requestError = nil;
        @try {
            if (![handler performRequests:@[ request ] error:&requestError]) {
                CGImageRelease(image);
                return axs_screenocr_helper_fail(requestError.localizedDescription ?: @"recognition failed", 5);
            }
        } @catch (NSException *exception) {
            CGImageRelease(image);
            return axs_screenocr_helper_fail(exception.reason ?: @"recognition crashed", 6);
        }
        CGImageRelease(image);

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
