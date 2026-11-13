//
//  OCRLog.h
//  ScreenOCR
//
//  日志同时写 NSLog 和 /var/mobile/Library/Logs/ScreenOCR.log，
//  设备上可以直接用 Filza 打开看，用来确认插件到底有没有被加载、有没有收到触发。
//

#pragma once

#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <time.h>
#import <unistd.h>

/// 改成 0 就不再往 Console 打，但文件日志始终保留（排查要紧）
#ifndef ScreenOCRConsoleLog
#define ScreenOCRConsoleLog 1
#endif

/// 日志文件超过这个大小就直接清掉重写
static const long long OCRLogMaxBytes = 400 * 1024;

static inline NSString *OCRLogFilePath(void) {
    // 沙盒外的真实路径，rootful / rootless / roothide 都一样
    return @"/var/mobile/Library/Logs/ScreenOCR.log";
}

static inline void OCRLogMessage(NSString *message) {
#if ScreenOCRConsoleLog
    NSLog(@"[ScreenOCR] %@", message);
#endif

    time_t now = time(NULL);
    struct tm localTime;
    localtime_r(&now, &localTime);

    char stamp[32];
    strftime(stamp, sizeof(stamp), "%m-%d %H:%M:%S", &localTime);

    NSString *line = [NSString stringWithFormat:@"%s [%d] %@\n", stamp, getpid(), message];
    NSString *path = OCRLogFilePath();
    NSString *directory = [path stringByDeletingLastPathComponent];
    mkdir(directory.fileSystemRepresentation, 0755);

    struct stat info;
    if (stat(path.fileSystemRepresentation, &info) == 0 && info.st_size > OCRLogMaxBytes) {
        unlink(path.fileSystemRepresentation);
    }

    int descriptor = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (descriptor < 0) return;

    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    (void)write(descriptor, data.bytes, data.length);
    close(descriptor);
}

#define OCRLog(fmt, ...) do { OCRLogMessage([NSString stringWithFormat:fmt, ##__VA_ARGS__]); } while (0)
