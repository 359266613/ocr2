//
//  OCREngine.m
//  ScreenOCR
//

#import "OCREngine.h"
#import "OCRConfig.h"
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>

#pragma mark - 工具函数

static CGImagePropertyOrientation OCRCGImageOrientation(UIImageOrientation orientation) {
    switch (orientation) {
        case UIImageOrientationDown:            return kCGImagePropertyOrientationDown;
        case UIImageOrientationLeft:            return kCGImagePropertyOrientationLeft;
        case UIImageOrientationRight:           return kCGImagePropertyOrientationRight;
        case UIImageOrientationUpMirrored:      return kCGImagePropertyOrientationUpMirrored;
        case UIImageOrientationDownMirrored:    return kCGImagePropertyOrientationDownMirrored;
        case UIImageOrientationLeftMirrored:    return kCGImagePropertyOrientationLeftMirrored;
        case UIImageOrientationRightMirrored:   return kCGImagePropertyOrientationRightMirrored;
        case UIImageOrientationUp:
        default:                                return kCGImagePropertyOrientationUp;
    }
}

/// 当前设备 Vision 真正支持的语言列表（缓存一次）
static NSArray<NSString *> *OCRSupportedLanguages(void) {
    static NSArray<NSString *> *languages;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        VNRecognizeTextRequest *probe = [[VNRecognizeTextRequest alloc] init];
        NSError *error = nil;
        NSArray<NSString *> *list = [probe supportedRecognitionLanguagesAndReturnError:&error];
        languages = list ?: @[ @"en-US" ];
        OCRLog(@"supported languages: %@", languages);
    });
    return languages;
}

static NSArray<NSString *> *OCRFilterLanguages(NSArray<NSString *> *requested) {
    NSArray<NSString *> *supported = OCRSupportedLanguages();
    if (!requested.count) return supported;

    NSMutableArray<NSString *> *valid = [NSMutableArray array];
    for (NSString *language in requested) {
        if ([supported containsObject:language]) [valid addObject:language];
    }
    return valid.count ? valid : supported;
}

/// 把 Vision 的观察结果按「从上到下、从左到右」拼成文本
static NSString *OCRTextFromResults(NSArray *results) {
    NSMutableArray<VNRecognizedTextObservation *> *observations = [NSMutableArray array];
    for (id object in results) {
        if (![object isKindOfClass:[VNRecognizedTextObservation class]]) continue;
        VNRecognizedTextObservation *observation = (VNRecognizedTextObservation *)object;
        if ([observation topCandidates:1].count == 0) continue;
        [observations addObject:observation];
    }

    [observations sortUsingComparator:^NSComparisonResult(VNRecognizedTextObservation *lhs,
                                                          VNRecognizedTextObservation *rhs) {
        CGRect left = lhs.boundingBox;
        CGRect right = rhs.boundingBox;
        // boundingBox 原点在左下角，midY 越大越靠上
        CGFloat deltaY = CGRectGetMidY(left) - CGRectGetMidY(right);
        if (fabs(deltaY) > 0.012) {
            return deltaY > 0 ? NSOrderedAscending : NSOrderedDescending;
        }
        return CGRectGetMinX(left) <= CGRectGetMinX(right) ? NSOrderedAscending : NSOrderedDescending;
    }];

    NSMutableString *text = [NSMutableString string];
    for (VNRecognizedTextObservation *observation in observations) {
        NSString *line = [observation topCandidates:1].firstObject.string;
        if (!line.length) continue;
        if (text.length) [text appendString:@"\n"];
        [text appendString:line];
    }
    return text.copy;
}

static void OCRDeliver(NSString *text, NSError *error, OCRTextCompletion completion) {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(text, error);
    });
}

#pragma mark - OCREngine

@implementation OCREngine

+ (void)recognizeImage:(UIImage *)image completion:(OCRTextCompletion)completion {
    [self recognizeImage:image languages:OCRLanguages() fastMode:NO completion:completion];
}

+ (void)recognizeImage:(UIImage *)image
             languages:(NSArray<NSString *> *)languages
              fastMode:(BOOL)fastMode
            completion:(OCRTextCompletion)completion {
    if (!image.CGImage) {
        NSError *error = [NSError errorWithDomain:@"ScreenOCR"
                                             code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"图像无效"}];
        OCRDeliver(nil, error, completion);
        return;
    }

    NSDate *startTime = [NSDate date];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block BOOL finished = NO;

        VNRecognizeTextRequest *request =
            [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *req, NSError *error) {
                if (finished) return;
                finished = YES;

                if (error) {
                    OCRLog(@"recognize error: %@", error);
                    OCRDeliver(nil, error, completion);
                    return;
                }
                NSString *text = OCRTextFromResults(req.results);
                OCRLog(@"recognize done, %lu chars, %.0f ms",
                       (unsigned long)text.length,
                       [[NSDate date] timeIntervalSinceDate:startTime] * 1000.0);
                OCRDeliver(text, nil, completion);
            }];

        request.recognitionLevel = fastMode ? VNRequestTextRecognitionLevelFast
                                            : VNRequestTextRecognitionLevelAccurate;
        request.usesLanguageCorrection = YES;

        if (@available(iOS 16.0, *)) {
            // 16 以上交给系统自动判断语种，中英混排更稳
            request.automaticallyDetectsLanguage = YES;
        } else {
            request.recognitionLanguages = OCRFilterLanguages(languages);
        }

        NSError *error = nil;
        VNImageRequestHandler *handler =
            [[VNImageRequestHandler alloc] initWithCGImage:image.CGImage
                                               orientation:OCRCGImageOrientation(image.imageOrientation)
                                                   options:@{}];
        [handler performRequests:@[request] error:&error];

        if (error && !finished) {
            finished = YES;
            OCRLog(@"performRequests error: %@", error);
            OCRDeliver(nil, error, completion);
        }
    });
}

@end
