#import "AxsScreenOcrLog.h"
#import "AxsScreenOcrPaths.h"

#import <unistd.h>

static dispatch_queue_t axs_screenocr_logQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.axs.screenocr.log", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString *axs_screenocr_logTimestamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"MM-dd HH:mm:ss.SSS";
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return [formatter stringFromDate:[NSDate date]];
}

void axs_screenocr_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"%@ [%d] %@\n",
                      axs_screenocr_logTimestamp(), getpid(), message];

    dispatch_async(axs_screenocr_logQueue(), ^{
        NSString *path = axs_screenocr_logPath();
        NSFileManager *manager = [NSFileManager defaultManager];
        [manager createDirectoryAtPath:[path stringByDeletingLastPathComponent]
           withIntermediateDirectories:YES attributes:nil error:NULL];

        NSDictionary *attributes = [manager attributesOfItemAtPath:path error:NULL];
        if ([attributes[NSFileSize] unsignedLongLongValue] > 512 * 1024) {
            [manager removeItemAtPath:path error:NULL];
        }

        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) {
            [data writeToFile:path atomically:YES];
            return;
        }
        @try {
            [handle seekToEndOfFile];
            [handle writeData:data];
        } @catch (__unused NSException *exception) {
            // 日志失败不影响主流程。
        }
        [handle closeFile];
    });
}
