#import "AxsScreenOcrVision.h"
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#import <TargetConditionals.h>
#import <math.h>
#import <unistd.h>

static NSString * const AxsScreenOcrVisionErrorDomain = @"com.axs.screenocr.vision";

static NSError *axs_screenocr_vision_error(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:AxsScreenOcrVisionErrorDomain code:code
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *axs_screenocr_vision_language_key(NSString *language) {
    return [[language stringByReplacingOccurrencesOfString:@"_" withString:@"-"] lowercaseString];
}

static NSString *axs_screenocr_vision_match(NSArray<NSString *> *supported, NSArray<NSString *> *candidates) {
    for (NSString *candidate in candidates) {
        for (NSString *language in supported) {
            if ([axs_screenocr_vision_language_key(language) isEqualToString:
                 axs_screenocr_vision_language_key(candidate)]) return language;
        }
    }
    return nil;
}

NSArray<NSString *> *axs_screenocr_vision_languages(NSArray<NSString *> *supported,
                                                   NSArray<NSString *> *preferred, BOOL *chinese) {
    NSString *first = axs_screenocr_vision_language_key(preferred.firstObject ?: @"");
    BOOL isChinese = first.length == 0 || [first hasPrefix:@"zh"] || [first hasPrefix:@"yue"]
        || [first containsString:@"hans"] || [first containsString:@"hant"];
    if (chinese) *chinese = isChinese;

    // ShellX sub_130ad4 narrows the supported list in this order.
    NSString *hans = axs_screenocr_vision_match(supported, @[@"zh-Hans", @"zh-CN", @"zh_Hans", @"zh"]);
    NSString *hant = axs_screenocr_vision_match(supported, @[@"zh-Hant", @"zh-TW", @"zh_Hant", @"zh-HK"]);
    NSString *english = axs_screenocr_vision_match(supported, @[@"en-US", @"en-GB", @"en"]);
    NSMutableArray<NSString *> *languages = [NSMutableArray array];
    if (isChinese) {
        // ShellX sub_130e54: preferred script first, then English; not both scripts.
        BOOL traditional = [first containsString:@"hant"] || [first hasPrefix:@"zh-tw"]
            || [first hasPrefix:@"zh-hk"] || [first hasPrefix:@"zh-mo"];
        NSString *script = traditional ? hant : hans;
        if (!script) {
            for (NSString *language in supported) {
                NSString *key = axs_screenocr_vision_language_key(language);
                if ([key hasPrefix:@"zh"] || [key hasPrefix:@"yue"]) {
                    script = language;
                    break;
                }
            }
        }
        if (script) [languages addObject:script];
    } else {
        for (NSString *preference in preferred) {
            NSString *key = axs_screenocr_vision_language_key(preference);
            NSString *base = [key componentsSeparatedByString:@"-"].firstObject;
            if ([base isEqualToString:@"zh"] || [base isEqualToString:@"yue"]) continue;
            if (([base isEqualToString:@"ja"] || [base isEqualToString:@"ko"]) && languages.count) continue;
            NSString *match = axs_screenocr_vision_match(supported, @[preference, base]);
            if (!match) {
                for (NSString *language in supported) {
                    if ([[axs_screenocr_vision_language_key(language) componentsSeparatedByString:@"-"].firstObject
                         isEqualToString:base]) {
                        match = language;
                        break;
                    }
                }
            }
            if (match && ![languages containsObject:match]) [languages addObject:match];
            if (languages.count >= 3) break;
        }
    }
    if (english && languages.count < 3 && ![languages containsObject:english]) [languages addObject:english];
    return languages.count ? languages : supported;
}

NSString *axs_screenocr_vision_describe_error(NSError *error) {
    if (!error) return @"Vision returned no NSError";
    NSMutableArray<NSString *> *details = [NSMutableArray array];
    NSMutableSet<NSError *> *seen = [NSMutableSet set];
    for (NSUInteger depth = 0; error && depth < 8 && ![seen containsObject:error]; depth++) {
        [seen addObject:error];
        [details addObject:[NSString stringWithFormat:@"%@/%ld: %@ userInfo=%@",
                           error.domain, (long)error.code, error.localizedDescription, error.userInfo]];
        id underlying = error.userInfo[NSUnderlyingErrorKey];
        error = [underlying isKindOfClass:[NSError class]] ? underlying : nil;
    }
    return [details componentsJoinedByString:@" -> "];
}

NSString *axs_screenocr_vision_environment(void) {
    NSProcessInfo *process = NSProcessInfo.processInfo;
    return [NSString stringWithFormat:@"core=shellx-vision-v2 process=%@ pid=%d uid=%u euid=%u "
            "bundle=%@ executable=%@ os=%@ preferred=%@",
            process.processName, getpid(), (unsigned)getuid(), (unsigned)geteuid(),
            NSBundle.mainBundle.bundleIdentifier ?: @"none", NSBundle.mainBundle.executablePath ?: @"none",
            process.operatingSystemVersionString, [NSLocale.preferredLanguages componentsJoinedByString:@","]];
}

static NSArray<NSDictionary *> *axs_screenocr_vision_perform(CGImageRef image,
    AxsScreenOcrVisionLogger logger, NSError **outError) {
    // performRequests is synchronous. Copy the completion state under a lock as the
    // completion handler may run on a framework worker thread.
    NSObject *lock = [NSObject new];
    __block NSError *completionError = nil;
    __block BOOL completed = NO;
    __block NSArray<VNRecognizedTextObservation *> *observations = nil;
    NSError *performError = nil;
    @try {
        VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc]
            initWithCompletionHandler:^(VNRequest *finishedRequest, NSError *error) {
                @synchronized (lock) {
                    completed = YES;
                    completionError = error;
                    observations = [finishedRequest.results copy];
                }
            }];
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        request.usesLanguageCorrection = NO;
        if (@available(iOS 16.0, macOS 13.0, *)) {
            request.revision = VNRecognizeTextRequestRevision3;
        } else {
            request.revision = VNRecognizeTextRequestRevision2;
        }
        request.minimumTextHeight = 0.0035f;
        NSError *languageError = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSArray<NSString *> *supported = [VNRecognizeTextRequest
            supportedRecognitionLanguagesForTextRecognitionLevel:request.recognitionLevel
            revision:request.revision error:&languageError];
#pragma clang diagnostic pop
        if (languageError || !supported.count) {
            if (outError) *outError = languageError ?: axs_screenocr_vision_error(1, @"Vision language list is empty");
            logger([@"language query failed: " stringByAppendingString:axs_screenocr_vision_describe_error(languageError)]);
            return nil;
        }
        BOOL chinese = NO;
        NSArray<NSString *> *languages = axs_screenocr_vision_languages(supported, NSLocale.preferredLanguages, &chinese);
        BOOL automatic = NO;
#if TARGET_OS_IOS
        NSInteger major = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
        automatic = major > 17 || (major == 17 && !chinese);
#endif
        if (@available(iOS 16.0, macOS 13.0, *)) request.automaticallyDetectsLanguage = automatic;
        if (!automatic) {
            request.recognitionLanguages = languages;
            request.usesLanguageCorrection = !chinese;
        }
        logger([NSString stringWithFormat:@"request revision=%lu accurate=1 correction=%d auto=%d "
                "minimumTextHeight=%.4f backend=system languages=%@ supported=%@",
                (unsigned long)request.revision, request.usesLanguageCorrection, automatic,
                request.minimumTextHeight, [request.recognitionLanguages componentsJoinedByString:@","],
                [supported componentsJoinedByString:@","]]);
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image
            orientation:kCGImagePropertyOrientationUp options:@{}];
        BOOL succeeded = [handler performRequests:@[request] error:&performError];
        NSArray<VNRecognizedTextObservation *> *results;
        NSError *callbackError;
        BOOL didComplete;
        @synchronized (lock) {
            results = observations;
            callbackError = completionError;
            didComplete = completed;
        }
        logger([NSString stringWithFormat:@"perform=%d completed=%d completionError=%@ performError=%@",
                succeeded, didComplete, callbackError ? axs_screenocr_vision_describe_error(callbackError) : @"none",
                performError ? axs_screenocr_vision_describe_error(performError) : @"none"]);
        if (!succeeded || callbackError || performError || !didComplete) {
            NSError *error = callbackError ?: performError ?: axs_screenocr_vision_error(2,
                @"Vision failed without NSError; see completion/perform and system model-loading logs");
            if (outError) *outError = error;
            return nil;
        }
        NSMutableArray<NSDictionary *> *lines = [NSMutableArray array];
        for (VNRecognizedTextObservation *observation in results) {
            VNRecognizedText *candidate = [observation topCandidates:1].firstObject;
            if (!candidate.string.length) continue;
            CGRect box = observation.boundingBox;
            [lines addObject:@{@"text": candidate.string, @"x": @(box.origin.x), @"y": @(box.origin.y),
                               @"w": @(box.size.width), @"h": @(box.size.height)}];
        }
        return lines;
    } @catch (NSException *exception) {
        NSError *error = axs_screenocr_vision_error(3, [NSString stringWithFormat:@"%@: %@",
                                                       exception.name, exception.reason ?: @"no reason"]);
        logger(axs_screenocr_vision_describe_error(error));
        if (outError) *outError = error;
        return nil;
    }
}

static BOOL axs_screenocr_vision_duplicate(NSDictionary *line, NSArray<NSDictionary *> *lines) {
    CGRect box = CGRectMake([line[@"x"] doubleValue], [line[@"y"] doubleValue],
                            [line[@"w"] doubleValue], [line[@"h"] doubleValue]);
    for (NSDictionary *existing in lines) {
        if (![line[@"text"] isEqualToString:existing[@"text"]]) continue;
        CGRect other = CGRectMake([existing[@"x"] doubleValue], [existing[@"y"] doubleValue],
                                  [existing[@"w"] doubleValue], [existing[@"h"] doubleValue]);
        CGRect intersection = CGRectIntersection(box, other);
        CGFloat area = MIN(box.size.width * box.size.height, other.size.width * other.size.height);
        if (!CGRectIsNull(intersection) && area > 0 &&
            intersection.size.width * intersection.size.height / area >= 0.5) return YES;
    }
    return NO;
}

NSArray<NSDictionary *> *axs_screenocr_vision_recognize(CGImageRef image,
    CGImagePropertyOrientation orientation, BOOL split, AxsScreenOcrVisionLogger logger, NSError **outError) {
    if (outError) *outError = nil;
    if (!image || orientation < 1 || orientation > 8) {
        if (outError) *outError = axs_screenocr_vision_error(4, @"Invalid image or orientation");
        return nil;
    }
    logger(axs_screenocr_vision_environment());
    // Normalize all eight EXIF orientations before cropping. CoreImage is used
    // instead of ShellX's UIKit redraw, without changing the pixel dimensions.
    CGImageRef normalized = NULL;
    @try {
        if (orientation == kCGImagePropertyOrientationUp) {
            normalized = CGImageRetain(image);
        } else {
            CIImage *input = [[CIImage imageWithCGImage:image] imageByApplyingOrientation:(int)orientation];
            CIContext *context = [CIContext contextWithOptions:nil];
            normalized = [context createCGImage:input fromRect:input.extent];
        }
        if (!normalized) {
            if (outError) *outError = axs_screenocr_vision_error(5, @"Cannot normalize image");
            return nil;
        }
        size_t width = CGImageGetWidth(normalized), height = CGImageGetHeight(normalized);
        NSUInteger parts = split && height >= 1400 ? ((height >= 2000 && height > width) ? 3 : 2) : 1;
        logger([NSString stringWithFormat:@"image=%zux%zu orientation=%u parts=%lu",
                width, height, (unsigned)orientation, (unsigned long)parts]);
        NSMutableArray<NSDictionary *> *lines = [NSMutableArray array];
        for (NSUInteger index = 0; index < parts; index++) {
            @autoreleasepool {
                CGFloat segment = (CGFloat)height / parts;
                CGFloat top = parts == 1 ? 0 : floor(MAX(0, index * segment - segment * 0.18));
                CGFloat bottom = parts == 1 ? height : MIN((CGFloat)height, (index + 1) * segment + segment * 0.18);
                CGFloat cropHeight = ceil(bottom - top);
                CGImageRef crop = CGImageCreateWithImageInRect(normalized, CGRectMake(0, top, width, cropHeight));
                if (!crop) {
                    if (outError) *outError = axs_screenocr_vision_error(6, @"Cannot crop image");
                    return nil;
                }
                NSArray<NSDictionary *> *partLines;
                @try {
                    partLines = axs_screenocr_vision_perform(crop, logger, outError);
                } @finally {
                    CGImageRelease(crop);
                }
                logger([NSString stringWithFormat:@"part=%lu/%lu top=%.0f height=%.0f success=%d lines=%lu",
                        (unsigned long)(index + 1), (unsigned long)parts, top, cropHeight,
                        partLines != nil, (unsigned long)partLines.count]);
                // A model-loading failure is not repaired by retrying other crops.
                if (!partLines) return nil;
                for (NSDictionary *item in partLines) {
                    NSMutableDictionary *mapped = [item mutableCopy];
                    mapped[@"y"] = @((height - top - cropHeight + [item[@"y"] doubleValue] * cropHeight) / height);
                    mapped[@"h"] = @([item[@"h"] doubleValue] * cropHeight / height);
                    if (!axs_screenocr_vision_duplicate(mapped, lines)) [lines addObject:mapped];
                }
            }
        }
        // Strict ordering avoids the old non-transitive "within .01" comparator.
        [lines sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            double leftY = [left[@"y"] doubleValue], rightY = [right[@"y"] doubleValue];
            if (leftY != rightY) return leftY > rightY ? NSOrderedAscending : NSOrderedDescending;
            return [left[@"x"] compare:right[@"x"]];
        }];
        return lines;
    } @catch (NSException *exception) {
        if (outError) *outError = axs_screenocr_vision_error(7, exception.reason ?: exception.name);
        return nil;
    } @finally {
        if (normalized) CGImageRelease(normalized);
    }
}
