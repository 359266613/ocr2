#import "AxsScreenOcrTrigger.h"
#import "AxsScreenOcrConfig.h"
#import "AxsScreenOcrLog.h"
#import "AxsScreenOcrRunner.h"

static NSString * const AxsScreenOcrTriggerToken = @"axsocr_recognize";
static NSString * const AxsScreenOcrTriggerTokenAlternate = @"axs_screenocr_recognize";

NSString *axs_screenocr_trigger_token(void) {
    return AxsScreenOcrTriggerToken;
}

BOOL axs_screenocr_url_matches(NSURL *url) {
    if (!url) return NO;

    NSString *absolute = url.absoluteString.lowercaseString;
    if (absolute.length == 0) return NO;

    // prefs:root=axsocr_recognize / app-prefs:root=axsocr_recognize /
    // prefs:root=com.axs.screenocr&path=recognize 都归到同一个触发词。
    if ([absolute containsString:AxsScreenOcrTriggerToken]) return YES;
    if ([absolute containsString:AxsScreenOcrTriggerTokenAlternate]) return YES;

    if ([url.scheme.lowercaseString isEqualToString:@"axs-screenocr"] ||
        [url.scheme.lowercaseString isEqualToString:@"screenocr"]) {
        NSString *host = url.host.lowercaseString ?: @"";
        if ([host isEqualToString:@"recognize"] || [host isEqualToString:@"ocr"]) return YES;
    }
    return NO;
}

// 只记录可能相关的 URL，避免每条系统链接都往日志里塞一行。
static BOOL axs_screenocr_url_is_interesting(NSURL *url) {
    if (!url) return NO;
    NSString *absolute = url.absoluteString.lowercaseString ?: @"";
    if (absolute.length == 0) return NO;

    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if ([scheme isEqualToString:@"prefs"] ||
        [scheme isEqualToString:@"app-prefs"] ||
        [scheme isEqualToString:@"axs-screenocr"] ||
        [scheme isEqualToString:@"screenocr"]) {
        return YES;
    }
    return [absolute containsString:@"ocr"];
}

void axs_screenocr_note_url(NSURL *url, NSString *source) {
    if (!axs_screenocr_url_is_interesting(url)) return;
    if (axs_screenocr_url_matches(url)) return;  // 匹配的走 handle_url，那里已经记过
    axs_screenocr_log(@"url seen via %@: %@（未匹配触发词）", source, url.absoluteString);
}

BOOL axs_screenocr_handle_url(NSURL *url) {
    if (!axs_screenocr_url_matches(url)) return NO;

    axs_screenocr_log(@"trigger: %@", url.absoluteString);

    if (![[AxsScreenOcrConfig axs_screenocr_shared] axs_screenocr_isEnabled]) {
        axs_screenocr_log(@"trigger ignored: plugin disabled in preferences");
        return NO;
    }

    // SpringBoard 与 UIApplication 的 hook 可能对同一次 openURL 各触发一次。
    static NSString *lastHandledURL = nil;
    static NSTimeInterval lastHandledTime = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if ([lastHandledURL isEqualToString:url.absoluteString] && now - lastHandledTime < 1.0) {
        axs_screenocr_log(@"trigger ignored: duplicate within 1s");
        return YES;
    }
    lastHandledURL = [url.absoluteString copy];
    lastHandledTime = now;

    if ([NSThread isMainThread]) {
        [AxsScreenOcrRunner axs_screenocr_run];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [AxsScreenOcrRunner axs_screenocr_run];
        });
    }
    return YES;
}
