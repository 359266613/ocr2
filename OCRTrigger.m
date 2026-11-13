//
//  OCRTrigger.m
//  ScreenOCR
//

#import "OCRTrigger.h"
#import "OCRConfig.h"
#import "OCRResultViewController.h"

/// 从 prefs:/app-prefs: 链接里取 root= 的值；没有就返回 nil
static NSString *OCRExtractRootValue(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"prefs"] && ![scheme isEqualToString:@"app-prefs"]) {
        return nil;
    }

    // prefs:root=axsocr_recognize 的 resourceSpecifier 就是 "root=axsocr_recognize"
    NSString *specifier = url.resourceSpecifier.lowercaseString;
    if (!specifier.length) return nil;

    NSRange range = [specifier rangeOfString:@"root="];
    if (range.location == NSNotFound) return nil;

    NSString *value = [specifier substringFromIndex:NSMaxRange(range)];
    NSRange end = [value rangeOfCharacterFromSet:
                   [NSCharacterSet characterSetWithCharactersInString:@"&#/?"]];
    return end.location == NSNotFound ? value : [value substringToIndex:end.location];
}

BOOL OCRURLMatchesTrigger(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;

    // 备用 scheme：screenocr://recognize
    NSString *scheme = url.scheme.lowercaseString;
    if ([scheme isEqualToString:@"screenocr"]) {
        NSString *host = (url.host ?: url.path ?: @"").lowercaseString;
        return [host isEqualToString:@"recognize"] || [host isEqualToString:@"ocr"];
    }

    NSString *value = OCRExtractRootValue(url);
    return value.length > 0 && [value isEqualToString:OCRTriggerToken().lowercaseString];
}

void OCRDismissOverlay(void) {
    [OCRResultViewController dismissCurrentOverlay];
}

void OCRRunRecognition(void) {
    OCRLog(@"trigger: run recognition, bundle=%@", OCRCurrentBundleID());

    OCRDismissOverlay();

    // 等手势动画 / 浮层收起结束再截图，否则会把它们截进去
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(OCRTriggerCaptureDelay() * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [OCRResultViewController captureAndPresentFromWindow:nil];
    });
}

BOOL OCRHandleTriggerURL(NSURL *url) {
    if (!OCRURLMatchesTrigger(url)) return NO;

    // 只有 SpringBoard 负责干活：App 进程里调用 openURL 时让它继续往系统走
    if (!OCRIsSpringBoard()) return NO;

    OCRLog(@"trigger: url=%@", url.absoluteString);

    // 0.6 秒内重复触发直接忽略（手势识别器偶尔会连发 began/ended）
    static CFAbsoluteTime lastTriggerTime = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastTriggerTime < OCRTriggerCooldown()) {
        OCRLog(@"trigger: ignored, too soon (%.2fs)", now - lastTriggerTime);
        return YES;
    }
    lastTriggerTime = now;

    dispatch_async(dispatch_get_main_queue(), ^{
        OCRRunRecognition();
    });
    return YES;
}
