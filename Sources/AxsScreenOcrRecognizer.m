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

NS_ASSUME_NONNULL_BEGIN

static NSString * const AxsScreenOcrErrorDomain = @"com.axs.screenocr";
static const int AxsScreenOcrRecognizeTimeout = 25;

@implementation AxsScreenOcrLine
@end

static NSError *axs_screenocr_error(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:AxsScreenOcrErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

NSString * _Nullable axs_screenocr_helper_path(void) {
    return axs_screenocr_resourcePath(@"/usr/libexec/AxsScreenOcrHelper");
}

static BOOL axs_screenocr_read_pipe(int fd, NSMutableData *output, int timeoutSeconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
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
            [output appendBytes:buffer length:(NSUInteger)count];
            continue;
        }
        if (count == 0) return YES;
        if (errno == EINTR) continue;
        return NO;
    }
}

NSArray<AxsScreenOcrLine *> * _Nullable
axs_screenocr_recognize_image_at_path(NSString *imagePath, NSError **error) {
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
    posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipeFDs[0]);

    char *arguments[] = {
        (char *)helper.fileSystemRepresentation,
        (char *)imagePath.fileSystemRepresentation,
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
    BOOL finished = axs_screenocr_read_pipe(pipeFDs[0], output, AxsScreenOcrRecognizeTimeout);
    close(pipeFDs[0]);

    if (!finished) {
        kill(pid, SIGKILL);
        axs_screenocr_log(@"helper timeout, killed pid=%d", pid);
    }

    int status = 0;
    waitpid(pid, &status, 0);

    if (output.length == 0) {
        if (error) {
            *error = axs_screenocr_error(13, finished ? @"识别进程没有返回结果"
                                                      : @"识别超时，请重试");
        }
        axs_screenocr_log(@"helper returned no data, status=%d", status);
        return nil;
    }

    NSError *jsonError = nil;
    id decoded = [NSJSONSerialization JSONObjectWithData:output options:0 error:&jsonError];
    if (![decoded isKindOfClass:[NSDictionary class]]) {
        NSString *raw = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
        axs_screenocr_log(@"helper output invalid: %@", [raw substringToIndex:MIN(raw.length, 200)]);
        if (error) *error = jsonError ?: axs_screenocr_error(14, @"识别结果格式异常");
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

NS_ASSUME_NONNULL_END
