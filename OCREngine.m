//
//  OCREngine.m
//  ScreenOCR
//
//  Vision 不在本进程里跑：SpringBoard 里加载文字识别模型会在 AppleNeuralEngine
//  里崩（SIGTRAP，直接 safemode）。所以截图存成 png，交给 /usr/libexec/ScreenOCRHelper
//  这个独立进程识别，它崩了只会让这一次识别失败。
//

#import "OCREngine.h"
#import "OCRConfig.h"
#import <UIKit/UIKit.h>
#import <errno.h>
#import <fcntl.h>
#import <poll.h>
#import <signal.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

static NSString * const OCRErrorDomain = @"ScreenOCR";

/// helper 的候选路径：rootless / roothide 在 /var/jb，rootful 在真实根
static NSString *OCRHelperPath(void) {
    static NSString *path;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *candidates = @[
            @"/var/jb/usr/libexec/ScreenOCRHelper",
            @"/usr/libexec/ScreenOCRHelper",
        ];
        for (NSString *candidate in candidates) {
            if (access(candidate.fileSystemRepresentation, X_OK) == 0) {
                path = candidate;
                break;
            }
        }
    });
    return path;
}

static NSError *OCRError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:OCRErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"识别失败"}];
}

/// 跑一次 helper，返回 stdout 文本；失败时返回 nil 并设置 error
static NSString *OCRRunHelper(NSString *imagePath, BOOL allowAnyDevice, NSError **error) {
    NSString *helper = OCRHelperPath();
    if (!helper) {
        OCRLog(@"helper missing (looked in /var/jb/usr/libexec and /usr/libexec)");
        if (error) *error = OCRError(10, @"找不到识别组件，请重新安装插件");
        return nil;
    }

    int outPipe[2];
    if (pipe(outPipe) != 0) {
        if (error) *error = OCRError(11, @"无法创建管道");
        return nil;
    }
    fcntl(outPipe[0], F_SETFD, FD_CLOEXEC);
    fcntl(outPipe[1], F_SETFD, FD_CLOEXEC);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    const char *helperPath = helper.fileSystemRepresentation;
    const char *argv[] = {
        helperPath,
        allowAnyDevice ? "--any" : "--safe",
        imagePath.fileSystemRepresentation,
        NULL,
    };

    pid_t pid = 0;
    int spawnResult = posix_spawn(&pid, helperPath, &actions, NULL, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(outPipe[1]);

    if (spawnResult != 0) {
        OCRLog(@"helper spawn failed: %d", spawnResult);
        close(outPipe[0]);
        if (error) *error = OCRError(12, @"无法启动识别组件");
        return nil;
    }

    NSMutableData *output = [NSMutableData data];
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + OCRRecognizeTimeout();
    BOOL timedOut = NO;

    for (;;) {
        int remaining = (int)((deadline - CFAbsoluteTimeGetCurrent()) * 1000);
        if (remaining <= 0) { timedOut = YES; break; }

        struct pollfd descriptor = { outPipe[0], POLLIN, 0 };
        int ready = poll(&descriptor, 1, remaining);
        if (ready < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (ready == 0) { timedOut = YES; break; }

        char buffer[4096];
        ssize_t count = read(outPipe[0], buffer, sizeof(buffer));
        if (count > 0) [output appendBytes:buffer length:(NSUInteger)count];
        else if (count == 0) break;              // EOF：helper 退出了
        else if (errno != EINTR) break;
    }
    close(outPipe[0]);

    if (timedOut) kill(pid, SIGKILL);

    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}

    if (timedOut) {
        if (error) *error = OCRError(13, @"识别超时");
        return nil;
    }
    if (WIFSIGNALED(status)) {
        OCRLog(@"helper crashed: signal %d", WTERMSIG(status));
        if (error) *error = OCRError(14, [NSString stringWithFormat:@"识别组件异常退出（信号 %d）", WTERMSIG(status)]);
        return nil;
    }

    NSString *text = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding] ?: @"";

    if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
        OCRLog(@"helper failed: code=%d output=%@", WEXITSTATUS(status),
              text.length > 800 ? [text substringToIndex:800] : text);
        NSString *detail = text.length > 0 ? [NSString stringWithFormat:@"\n%@", text] : @"";
        if (error) *error = OCRError(15, [NSString stringWithFormat:@"识别失败（代码 %d）%@",
                                          WEXITSTATUS(status), detail]);
        return nil;
    }

    return text;
}

@implementation OCREngine

+ (void)recognizeImage:(UIImage *)image completion:(OCRTextCompletion)completion {
    [self recognizeImage:image languages:OCRLanguages() fastMode:NO completion:completion];
}

+ (void)recognizeImage:(UIImage *)image
             languages:(NSArray<NSString *> *)languages
              fastMode:(BOOL)fastMode
            completion:(OCRTextCompletion)completion {
    (void)languages;
    (void)fastMode;

    if (!image.CGImage) {
        NSError *error = OCRError(-1, @"图像无效");
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
        }
        return;
    }

    NSDate *startTime = [NSDate date];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // SpringBoard 的 NSTemporaryDirectory 不可靠，用 mobile 一定可写的公共目录
        NSString *directory = @"/var/mobile/Library/Caches/ScreenOCR";
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSString *path = [directory stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"%@.png", [NSUUID UUID].UUIDString]];

        NSData *png = UIImagePNGRepresentation(image);
        NSError *error = nil;
        NSString *text = nil;

        if (!png || ![png writeToFile:path options:NSDataWritingAtomic error:&error]) {
            error = error ?: OCRError(2, @"无法保存截图");
            OCRLog(@"save png failed: %@", error.localizedDescription);
        } else {
            OCRLog(@"recognize: image=%@ png=%luB", NSStringFromCGSize(image.size), (unsigned long)png.length);
            // 先只用 CPU；不行再放开默认计算设备（崩也只崩 helper）
            for (NSInteger attempt = 0; attempt < 2 && text == nil; attempt++) {
                error = nil;
                text = OCRRunHelper(path, attempt > 0, &error);
            }
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        }

        double elapsed = [[NSDate date] timeIntervalSinceDate:startTime] * 1000.0;
        OCRLog(@"recognize done: %ld chars, %.0f ms", (long)text.length, elapsed);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!completion) return;
            if (text == nil) {
                completion(nil, error ?: OCRError(3, @"识别失败"));
            } else if (text.length == 0) {
                completion(nil, OCRError(4, @"没有识别到文字"));
            } else {
                completion(text, nil);
            }
        });
    });
}

@end
