#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import "AxsScreenOcrVision.h"
#import "AxsScreenOcrPaths.h"
#import <errno.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

static void axs_screenocr_helper_note(NSString *message) {
    fprintf(stderr, "%s\n", message.UTF8String ?: "");
    fflush(stderr);
}

static void axs_screenocr_helper_open_log(void) {
    NSString *path = axs_screenocr_userLibraryPath(@"Logs/AxsScreenOcrHelper.log");
    NSFileManager *manager = NSFileManager.defaultManager;
    [manager createDirectoryAtPath:path.stringByDeletingLastPathComponent
      withIntermediateDirectories:YES attributes:nil error:NULL];
    if ([[manager attributesOfItemAtPath:path error:NULL][NSFileSize] unsignedLongLongValue] > 256 * 1024) {
        [manager removeItemAtPath:path error:NULL];
    }
    (void)freopen(path.fileSystemRepresentation, "a", stderr);
}

static int axs_screenocr_helper_emit(NSDictionary *payload) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
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
    axs_screenocr_helper_note([NSString stringWithFormat:@"fail(%d): %@", code, message]);
    axs_screenocr_helper_emit(@{@"ok": @NO, @"error": message});
    return code;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        int gidResult = setgid(501), gidError = gidResult == 0 ? 0 : errno;
        int uidResult = setuid(501), uidError = uidResult == 0 ? 0 : errno;
        axs_screenocr_helper_open_log();
        axs_screenocr_helper_note([NSString stringWithFormat:
            @"--- helper start setuid=%d/%d setgid=%d/%d", uidResult, uidError, gidResult, gidError]);
        if (argc < 2 || argc > 4) return axs_screenocr_helper_fail(@"expected image [orientation] [--single]", 2);
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        if (!path.length) return axs_screenocr_helper_fail(@"invalid image path", 2);
        char *end = NULL;
        long value = argc >= 3 ? strtol(argv[2], &end, 10) : 1;
        if (argc >= 3 && (end == argv[2] || !end || *end || value < 1 || value > 8)) {
            return axs_screenocr_helper_fail(@"invalid image orientation", 2);
        }
        BOOL single = argc == 4 && strcmp(argv[3], "--single") == 0;
        if (argc == 4 && !single) return axs_screenocr_helper_fail(@"unknown option", 2);
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
        if (!source) return axs_screenocr_helper_fail(@"cannot open image", 3);
        CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
        if (!image) return axs_screenocr_helper_fail(@"cannot decode image", 4);
        NSError *error = nil;
        NSArray<NSDictionary *> *lines;
        @try {
            lines = axs_screenocr_vision_recognize(image, (CGImagePropertyOrientation)value, !single,
                ^(NSString *message) { axs_screenocr_helper_note(message); }, &error);
        } @finally {
            CGImageRelease(image);
        }
        if (!lines) return axs_screenocr_helper_fail(axs_screenocr_vision_describe_error(error), 8);
        axs_screenocr_helper_note([NSString stringWithFormat:@"done: %lu lines", (unsigned long)lines.count]);
        return axs_screenocr_helper_emit(@{@"ok": @YES, @"lines": lines});
    }
}
