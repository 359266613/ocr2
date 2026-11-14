#import "AxsScreenOcrRecognizer.h"
#import "AxsScreenOcrLog.h"
#import "AxsScreenOcrPaths.h"

#import <errno.h>
#import <signal.h>
#import <spawn.h>
#import <sys/select.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;


static NSString * const AxsScreenOcrErrorDomain = @"com.axs.screenocr";
static const int AxsScreenOcrRecognizeTimeout = 60;

@implementation AxsScreenOcrLine
@end

static NSError *axs_screenocr_error(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:AxsScreenOcrErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *axs_screenocr_helper_path(void) {
    return axs_screenocr_resourcePath(@"/usr/libexec/AxsScreenOcrHelper");
}

static BOOL axs_screenocr_read_pipe(int fd, NSMutableData *output, NSDate *deadline) {
    char buffer[4096];
    while (YES) {
        NSTimeInterval remaining = [deadline timeIntervalSinceNow];
        if (remaining <= 0) return NO;

        fd_set readSet;
        FD_ZERO(&readSet);
        FD_SET(fd, &readSet);
        struct timeval timeout;
        timeout.tv_sec = 0;
        timeout.tv_usec = 200 * 1000;

        int ready = select(fd + 1, &readSet, NULL, NULL, &timeout);
        if (ready < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (ready == 0) continue;

        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count > 0) {
            if (output.length + (NSUInteger)count > 4 * 1024 * 1024) return NO;
            [output appendBytes:buffer length:(NSUInteger)count];
            continue;
        }
        if (count == 0) return YES;
        if (errno == EINTR) continue;
        return NO;
    }
}

// helper 的 stdout 理论上只有一行 JSON，但系统框架偶尔仍会往 fd 1 写日志。
// 先整体解析，失败再从尾部回溯，取最后一个能独立解析的对象。
static id axs_screenocr_decode_payload(NSData *output) {
    if (output.length == 0) return nil;

    id decoded = [NSJSONSerialization JSONObjectWithData:output options:0 error:NULL];
    if ([decoded isKindOfClass:[NSDictionary class]]) return decoded;

    NSString *text = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
    if (text.length == 0) return nil;

    NSRange search = NSMakeRange(0, text.length);
    while (search.length > 0) {
        NSRange brace = [text rangeOfString:@"{" options:NSBackwardsSearch range:search];
        if (brace.location == NSNotFound) break;

        NSString *candidate = [text substringFromIndex:brace.location];
        id partial = [NSJSONSerialization JSONObjectWithData:
                      [candidate dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        if ([partial isKindOfClass:[NSDictionary class]]) return partial;

        if (brace.location == 0) break;
        search = NSMakeRange(0, brace.location);
    }
    return nil;
}

static NSArray<AxsScreenOcrLine *> *axs_screenocr_run_helper(NSString *imagePath,
    CGImagePropertyOrientation orientation, BOOL single, NSError **error) {
    NSString *helper = axs_screenocr_helper_path();
    if (helper.length == 0 || ![[NSFileManager defaultManager] isExecutableFileAtPath:helper]) {
        if (error) *error = axs_screenocr_error(10, @"识别组件缺失，请重新安装插件");
        axs_screenocr_log(@"helper missing at %@", helper ?: @"(nil)");
        return nil;
    }

    int pipeFDs[2] = { -1, -1 };
    if (pipe(pipeFDs) != 0) {
        if (error) *error = axs_screenocr_error(11, @"无法创建管道");
        return nil;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    // 只把 stdout 接进管道。stderr 由 helper 写入独立日志，
    // 否则框架日志会混进 JSON，把正常结果判定成「格式不正确」。
    posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipeFDs[0]);
    posix_spawn_file_actions_addclose(&actions, pipeFDs[1]);

    NSString *orientationArgument = [NSString stringWithFormat:@"%u", (unsigned int)orientation];
    char *arguments[] = {
        (char *)helper.fileSystemRepresentation,
        (char *)imagePath.fileSystemRepresentation,
        (char *)orientationArgument.UTF8String,
        single ? (char *)"--single" : NULL,
        NULL
    };

    pid_t pid = 0;
    int spawnResult = posix_spawn(&pid, helper.fileSystemRepresentation, &actions, NULL,
                                  arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(pipeFDs[1]);

    if (spawnResult != 0) {
        close(pipeFDs[0]);
        if (error) *error = axs_screenocr_error(12, @"无法启动识别组件");
        axs_screenocr_log(@"helper spawn failed: %d", spawnResult);
        return nil;
    }

    NSMutableData *output = [NSMutableData data];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:AxsScreenOcrRecognizeTimeout];
    BOOL finished = axs_screenocr_read_pipe(pipeFDs[0], output, deadline);
    close(pipeFDs[0]);

    int status = 0;
    pid_t waited = 0;
    while (finished && [deadline timeIntervalSinceNow] > 0) {
        waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid) break;
        if (waited < 0) {
            if (errno != EINTR) break;
            waited = 0;
        }
        usleep(20000);
    }
    if (finished && waited == 0) finished = NO;
    if (!finished) {
        kill(pid, SIGKILL);
        axs_screenocr_log(@"helper timed out or output exceeded limit, killed pid=%d", pid);
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
        if (error) *error = axs_screenocr_error(13, @"识别组件超时或输出过大");
        return nil;
    }
    if (waited < 0) {
        axs_screenocr_log(@"helper wait failed: %d", errno);
        if (error) *error = axs_screenocr_error(16, @"无法获取识别组件状态");
        return nil;
    }
    if (WIFSIGNALED(status)) {
        axs_screenocr_log(@"helper terminated by signal %d", WTERMSIG(status));
        if (error) *error = axs_screenocr_error(17, @"识别组件异常退出，请查看辅助日志或崩溃报告");
        return nil;
    }

    if (output.length == 0) {
        if (error) {
            *error = axs_screenocr_error(13, @"识别进程没有返回结果");
        }
        axs_screenocr_log(@"helper returned no data, status=%d", status);
        return nil;
    }

    id decoded = axs_screenocr_decode_payload(output);
    if (![decoded isKindOfClass:[NSDictionary class]]) {
        axs_screenocr_log(@"helper output invalid: %lu bytes", (unsigned long)output.length);
        if (error) *error = axs_screenocr_error(14, @"识别结果格式异常");
        return nil;
    }

    NSDictionary *payload = (NSDictionary *)decoded;
    if (![payload[@"ok"] boolValue]) {
        NSString *message = [payload[@"error"] isKindOfClass:[NSString class]]
            ? payload[@"error"] : @"识别失败";
        if (error) *error = axs_screenocr_error(15, message);
        axs_screenocr_log(@"helper reported error: %@", message);
        return nil;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        axs_screenocr_log(@"helper exited unexpectedly: status=%d", status);
        if (error) *error = axs_screenocr_error(18, @"识别组件退出状态异常");
        return nil;
    }

    NSMutableArray<AxsScreenOcrLine *> *lines = [NSMutableArray array];
    id items = payload[@"lines"];
    if ([items isKindOfClass:[NSArray class]]) {
        for (NSDictionary *item in (NSArray *)items) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString *text = item[@"text"];
            if (![text isKindOfClass:[NSString class]] || text.length == 0) continue;
            AxsScreenOcrLine *line = [[AxsScreenOcrLine alloc] init];
            line.text = text;
            line.box = CGRectMake([item[@"x"] doubleValue], [item[@"y"] doubleValue],
                                  [item[@"w"] doubleValue], [item[@"h"] doubleValue]);
            [lines addObject:line];
        }
    }
    return lines;
}

NSArray<AxsScreenOcrLine *> *axs_screenocr_recognize_image_at_path(NSString *imagePath,
    CGImagePropertyOrientation orientation, NSError **error) {
    return axs_screenocr_run_helper(imagePath, orientation, NO, error);
}

NSArray<AxsScreenOcrLine *> *axs_screenocr_recognize_single_image_at_path(NSString *imagePath, NSError **error) {
    return axs_screenocr_run_helper(imagePath, kCGImagePropertyOrientationUp, YES, error);
}
