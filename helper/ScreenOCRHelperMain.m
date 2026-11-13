//
//  ScreenOCRHelperMain.m
//  ScreenOCRHelper
//
//  用法：ScreenOCRHelper [--safe|--any] <图片路径>
//  成功：stdout 输出识别到的文字（每行一段），退出码 0
//  失败：stdout 输出 Vision 的错误原因，退出码 4
//
//  为什么要独立进程：在 SpringBoard 里加载文字识别模型会在 AppleNeuralEngine 里
//  触发 SIGTRAP，直接把 SpringBoard 干掉（进 safemode）。放到这里，崩了只会让
//  这一次识别失败，系统不受影响。
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h>

typedef struct {
    BOOL fast;
    BOOL cpuOnly;
    BOOL ownBuffer;   // 自己分配 CVPixelBuffer 喂给 Vision，而不是让 Vision 自己转
} ScreenOCRHelperConfig;

__attribute__((noreturn))
static void ScreenOCRHelperFinish(int code) {
    fflush(stdout);
    // 故意跳过 Objective-C / C++ 的退出清理：释放识别模型会在 AppleNeuralEngine
    // 里 abort，输出已经 flush 过了，直接 _exit 最安全。
    _exit(code);
}

static NSArray<NSString *> *ScreenOCRHelperLanguages(VNRecognizeTextRequest *request) {
    NSError *error = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray<NSString *> *supported = [request supportedRecognitionLanguagesAndReturnError:&error];
#pragma clang diagnostic pop
    if (supported.count == 0) return nil;

    NSMutableArray<NSString *> *languages = [NSMutableArray array];
    for (NSString *language in @[ @"zh-Hans", @"zh-Hant", @"en-US" ]) {
        if ([supported containsObject:language]) [languages addObject:language];
    }
    return languages.count > 0 ? languages : nil;
}

// 把图绘制到普通内存的 BGRA buffer（不带 IOSurface 属性）
static CVPixelBufferRef ScreenOCRHelperCreateBuffer(CGImageRef image) {
    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    NSDictionary *attributes = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };

    CVPixelBufferRef buffer = NULL;
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)attributes, &buffer);
    if (result != kCVReturnSuccess || !buffer) return NULL;

    CVPixelBufferLockBaseAddress(buffer, 0);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer),
                                                 width, height, 8,
                                                 CVPixelBufferGetBytesPerRow(buffer),
                                                 colorSpace,
                                                 kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(colorSpace);
    if (context) {
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
        CGContextRelease(context);
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);

    if (!context) {
        CVPixelBufferRelease(buffer);
        return NULL;
    }
    return buffer;
}

static NSString *ScreenOCRHelperRecognize(CGImageRef image, ScreenOCRHelperConfig config,
                                          NSError **error) {
    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:nil];
    request.recognitionLevel = config.fast ? VNRequestTextRecognitionLevelFast
                                           : VNRequestTextRecognitionLevelAccurate;
    request.usesLanguageCorrection = !config.fast;

    NSArray<NSString *> *languages = ScreenOCRHelperLanguages(request);
    if (languages) request.recognitionLanguages = languages;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    request.usesCPUOnly = config.cpuOnly;
#pragma clang diagnostic pop

    CVPixelBufferRef buffer = NULL;
    VNImageRequestHandler *handler = nil;

    if (config.ownBuffer) {
        buffer = ScreenOCRHelperCreateBuffer(image);
        if (!buffer) {
            if (error) {
                *error = [NSError errorWithDomain:@"ScreenOCRHelper" code:1
                                         userInfo:@{NSLocalizedDescriptionKey: @"cannot allocate pixel buffer"}];
            }
            return nil;
        }
        handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:buffer options:@{}];
    } else {
        handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    }

    BOOL ok = [handler performRequests:@[ request ] error:error];
    if (buffer) CVPixelBufferRelease(buffer);
    if (!ok) return nil;

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (VNRecognizedTextObservation *observation in request.results) {
        NSString *line = [observation topCandidates:1].firstObject.string;
        if (line.length > 0) [lines addObject:line];
    }
    return [lines componentsJoinedByString:@"\n"];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) {
            fputs("usage: ScreenOCRHelper [--safe|--any] <image path>\n", stderr);
            ScreenOCRHelperFinish(2);
        }

        BOOL allowAnyDevice = strcmp(argv[1], "--any") == 0;
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];

        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
        if (!image) {
            fputs("cannot load image\n", stdout);
            ScreenOCRHelperFinish(3);
        }

        // 先精确后快速，先 CPU 后默认设备，先 CGImage 后自建 buffer
        ScreenOCRHelperConfig configs[] = {
            { NO,  YES, NO }, { NO,  YES, YES }, { YES, YES, NO }, { YES, YES, YES },
            { NO,  NO,  NO }, { NO,  NO,  YES }, { YES, NO,  NO }, { YES, NO,  YES },
        };
        NSInteger count = allowAnyDevice ? 8 : 4;

        NSMutableArray<NSString *> *failures = [NSMutableArray array];
        for (NSInteger index = 0; index < count; index++) {
            ScreenOCRHelperConfig config = configs[index];
            NSError *error = nil;
            NSString *text = ScreenOCRHelperRecognize(image, config, &error);
            if (text) {
                fputs(text.UTF8String, stdout);
                ScreenOCRHelperFinish(0);
            }

            NSString *reason = error.localizedDescription;
            if (error.localizedFailureReason.length > 0) {
                reason = [reason stringByAppendingFormat:@" | %@", error.localizedFailureReason];
            }
            NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
            if (underlying) {
                reason = [reason stringByAppendingFormat:@" | underlying: %@", underlying.localizedDescription];
            }
            [failures addObject:[NSString stringWithFormat:@"%@%@%@: %@",
                                 config.fast ? @"fast" : @"accurate",
                                 config.cpuOnly ? @"+cpu" : @"",
                                 config.ownBuffer ? @"+buf" : @"",
                                 reason ?: @"unknown error"]];
        }

        fputs([failures componentsJoinedByString:@"\n"].UTF8String, stdout);
        ScreenOCRHelperFinish(4);
    }
}
