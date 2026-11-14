#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h>
#import <errno.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>

// 独立识别进程：由 SpringBoard 内的 dylib 以 posix_spawn 启动。
// 参数为 PNG 路径和图片方向，结果以单行 JSON 写到 stdout。

static NSString * const AxsScreenOcrHelperLogDirectory = @"/var/mobile/Library/Logs";
static NSString * const AxsScreenOcrHelperLogFile = @"/var/mobile/Library/Logs/AxsScreenOcrHelper.log";
static const unsigned long long AxsScreenOcrHelperLogLimit = 256 * 1024;

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

// 与分析到的 ShellX Vision 请求一致：Accurate、关闭语言纠正，
// 不强制 CPU；在独立进程中运行以隔离系统框架崩溃。
static VNRecognizeTextRequest *axs_screenocr_helper_request(void) {
    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
    if (@available(iOS 16.0, *)) {
        request.revision = VNRecognizeTextRequestRevision3;
    } else if (@available(iOS 14.0, *)) {
        request.revision = VNRecognizeTextRequestRevision2;
    }
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    request.usesLanguageCorrection = NO;
    if (@available(iOS 16.0, *)) {
        request.automaticallyDetectsLanguage = NO;
    }
    NSError *languageError = nil;
    NSArray<NSString *> *supported;
    if (@available(iOS 15.0, *)) {
        supported = [request supportedRecognitionLanguagesAndReturnError:&languageError];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        supported = [VNRecognizeTextRequest supportedRecognitionLanguagesForTextRecognitionLevel:request.recognitionLevel
                                                                                       revision:request.revision error:&languageError];
#pragma clang diagnostic pop
    }
    NSMutableArray<NSString *> *languages = [NSMutableArray array];
    NSArray<NSString *> *preferred = [NSLocale preferredLanguages];
    for (NSString *preferredLanguage in [preferred arrayByAddingObjectsFromArray:@[@"zh-Hans", @"zh-Hant", @"en-US"]]) {
        NSString *match = nil;
        for (NSString *candidate in supported) {
            if ([candidate caseInsensitiveCompare:preferredLanguage] == NSOrderedSame) {
                match = candidate;
                break;
            }
        }
        if (!match) {
            NSString *prefix = [[preferredLanguage componentsSeparatedByString:@"-"] firstObject];
            for (NSString *candidate in supported) {
                if ([[[candidate componentsSeparatedByString:@"-"] firstObject] caseInsensitiveCompare:prefix] == NSOrderedSame) {
                    match = candidate;
                    break;
                }
            }
        }
        if (match && ![languages containsObject:match]) [languages addObject:match];
    }
    if (languages.count) request.recognitionLanguages = languages;
    axs_screenocr_helper_note(@"supported languages=%@ error=%@",
                              [supported componentsJoinedByString:@","] ?: @"unknown",
                              languageError.localizedDescription ?: @"none");
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

// 跑一轮识别。返回 YES 表示请求本身跑通了（lines 可能为空，即画面无文字）；
// 返回 NO 表示框架层失败（例如申请不到像素缓冲），原因写进 outError。
static BOOL axs_screenocr_helper_perform(CGImageRef image,
                                         CGImagePropertyOrientation orientation,
                                         NSMutableArray<NSDictionary *> *lines,
                                         NSError **outError) {
    NSError *error = nil;
    BOOL succeeded = NO;
    VNRecognizeTextRequest *request = nil;

    @try {
        VNImageRequestHandler *handler =
            [[VNImageRequestHandler alloc] initWithCGImage:image orientation:orientation options:@{}];
        request = axs_screenocr_helper_request();
        axs_screenocr_helper_note(@"vision revision=%lu level=accurate correction=0 backend=system languages=%@",
                                  (unsigned long)request.revision,
                                  [request.recognitionLanguages componentsJoinedByString:@","]);
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
        axs_screenocr_helper_note(@"accurate failed: %@", axs_screenocr_helper_describe(error));
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

static BOOL axs_screenocr_helper_duplicate(NSDictionary *line, NSArray<NSDictionary *> *lines) {
    CGRect box = CGRectMake([line[@"x"] doubleValue], [line[@"y"] doubleValue],
                            [line[@"w"] doubleValue], [line[@"h"] doubleValue]);
    for (NSDictionary *existing in lines) {
        if (![line[@"text"] isEqualToString:existing[@"text"]]) continue;
        CGRect other = CGRectMake([existing[@"x"] doubleValue], [existing[@"y"] doubleValue],
                                  [existing[@"w"] doubleValue], [existing[@"h"] doubleValue]);
        CGRect intersection = CGRectIntersection(box, other);
        if (CGRectIsNull(intersection)) continue;
        CGFloat area = MIN(box.size.width * box.size.height, other.size.width * other.size.height);
        if (area > 0 && intersection.size.width * intersection.size.height / area >= 0.5) return YES;
    }
    return NO;
}

// main 是工具链固定入口名，按约定保留原名。
int main(int argc, char *argv[]) {
    @autoreleasepool {
        // 保留 mobile 身份尝试，同时记录实际身份和切换结果。
        int gidResult = setgid(501);
        int gidError = gidResult == 0 ? 0 : errno;
        int uidResult = setuid(501);
        int uidError = uidResult == 0 ? 0 : errno;

        axs_screenocr_helper_open_log();
        axs_screenocr_helper_note(@"--- helper start pid=%d", (int)getpid());
        axs_screenocr_helper_note(@"identity uid=%u euid=%u gid=%u egid=%u setuid=%d/%d setgid=%d/%d",
                                  (unsigned)getuid(), (unsigned)geteuid(), (unsigned)getgid(), (unsigned)getegid(),
                                  uidResult, uidError, gidResult, gidError);

        if (argc < 2) return axs_screenocr_helper_fail(@"missing image path", 2);

        NSString *path = [NSString stringWithUTF8String:argv[1]];
        if (path.length == 0) return axs_screenocr_helper_fail(@"invalid image path", 2);
        char *end = NULL;
        long orientationValue = argc >= 3 ? strtol(argv[2], &end, 10) : 1;
        if (argc >= 3 && (!end || *end != '\0' || orientationValue < 1 || orientationValue > 8)) {
            return axs_screenocr_helper_fail(@"invalid image orientation", 2);
        }
        CGImagePropertyOrientation orientation = (CGImagePropertyOrientation)orientationValue;
        axs_screenocr_helper_note(@"orientation=%ld", orientationValue);

        NSURL *url = [NSURL fileURLWithPath:path];
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        if (!source) return axs_screenocr_helper_fail(@"cannot open image", 3);

        CGImageRef original = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
        if (!original) return axs_screenocr_helper_fail(@"cannot decode image", 4);

        size_t pixelWidth = CGImageGetWidth(original);
        size_t pixelHeight = CGImageGetHeight(original);
        NSUInteger parts = 1;
        if (orientation == kCGImagePropertyOrientationUp && pixelHeight > 1400) {
            parts = (pixelHeight >= 2000 && pixelHeight > pixelWidth) ? 3 : 2;
        }
        axs_screenocr_helper_note(@"image %zux%zu parts=%lu overlap=0.18",
                                  pixelWidth, pixelHeight, (unsigned long)parts);
        NSMutableArray<NSDictionary *> *lines = [NSMutableArray array];
        BOOL performedAny = NO;
        NSError *firstError = nil;
        for (NSUInteger index = 0; index < parts; index++) {
            CGFloat segment = (CGFloat)pixelHeight / parts;
            CGFloat top = floor(MAX(0, index * segment - segment * 0.18));
            CGFloat bottom = ceil(MIN((CGFloat)pixelHeight, (index + 1) * segment + segment * 0.18));
            CGRect cropRect = CGRectMake(0, top, pixelWidth, bottom - top);
            CGImageRef crop = parts == 1 ? CGImageRetain(original) : CGImageCreateWithImageInRect(original, cropRect);
            if (!crop) {
                axs_screenocr_helper_note(@"part %lu crop failed", (unsigned long)index);
                if (!firstError) firstError = [NSError errorWithDomain:@"com.axs.screenocr.helper" code:2
                    userInfo:@{NSLocalizedDescriptionKey: @"无法裁剪截图"}];
                continue;
            }
            NSError *error = nil;
            NSMutableArray<NSDictionary *> *partLines = [NSMutableArray array];
            BOOL performed = axs_screenocr_helper_perform(crop, orientation, partLines, &error);
            CGImageRelease(crop);
            axs_screenocr_helper_note(@"part %lu/%lu y=%.0f height=%.0f -> %@ lines=%lu",
                                      (unsigned long)(index + 1), (unsigned long)parts, top, bottom - top,
                                      performed ? @"ok" : @"failed", (unsigned long)partLines.count);
            if (!performed) {
                if (!firstError) firstError = error ?: [NSError errorWithDomain:@"com.axs.screenocr.helper" code:3
                    userInfo:@{NSLocalizedDescriptionKey: @"Vision 未返回错误详情"}];
                continue;
            }
            performedAny = YES;
            for (NSDictionary *item in partLines) {
                NSMutableDictionary *mapped = [item mutableCopy];
                if (parts > 1) {
                    CGFloat partHeight = bottom - top;
                    mapped[@"y"] = @(((CGFloat)pixelHeight - bottom + [item[@"y"] doubleValue] * partHeight) / pixelHeight);
                    mapped[@"h"] = @([item[@"h"] doubleValue] * partHeight / pixelHeight);
                }
                if (!axs_screenocr_helper_duplicate(mapped, lines)) [lines addObject:mapped];
            }
        }
        CGImageRelease(original);

        if (firstError) {
            return axs_screenocr_helper_fail(axs_screenocr_helper_describe(firstError), 8);
        }
        if (lines.count == 0) {
            if (performedAny) {
                axs_screenocr_helper_note(@"no text in image");
                return axs_screenocr_helper_fail(@"画面中没有识别到文字", 7);
            }
            return axs_screenocr_helper_fail(axs_screenocr_helper_describe(firstError), 8);
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

        axs_screenocr_helper_note(@"done: %lu lines", (unsigned long)lines.count);
        return axs_screenocr_helper_emit(@{ @"ok": @YES, @"lines": lines });
    }
}
