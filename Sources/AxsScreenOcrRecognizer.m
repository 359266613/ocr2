#import "AxsScreenOcrRecognizer.h"
#import "AxsScreenOcrLog.h"
#import "AxsScreenOcrPaths.h"

#import <Vision/Vision.h>
#import <errno.h>
#import <math.h>
#import <signal.h>
#import <spawn.h>
#import <sys/select.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;


static NSString * const AxsScreenOcrErrorDomain = @"com.axs.screenocr";
// helper 内部会按 1.0 / 0.75 / 0.55 三档分辨率依次尝试，耗时高于单轮识别。
static const int AxsScreenOcrRecognizeTimeout = 40;

@implementation AxsScreenOcrLine
@end

static NSError *axs_screenocr_error(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:AxsScreenOcrErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

// 进程内识别跑在 SpringBoard 里，它持有完整的 ANE / Espresso 权限，
// 所以这里不强制 CPU 后端，交给 Vision 自己挑，速度更快。
static VNRecognizeTextRequest *axs_screenocr_make_request(VNRequestTextRecognitionLevel level) {
    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
    request.recognitionLevel = level;
    request.usesLanguageCorrection = YES;
    request.recognitionLanguages = @[ @"zh-Hans", @"zh-Hant", @"en-US" ];
    if (@available(iOS 16.0, *)) {
        request.automaticallyDetectsLanguage = YES;
    }
    return request;
}

static NSArray<AxsScreenOcrLine *> *axs_screenocr_lines_from_request(VNRecognizeTextRequest *request) {
    NSMutableArray<AxsScreenOcrLine *> *lines = [NSMutableArray array];
    for (VNRecognizedTextObservation *observation in request.results) {
        VNRecognizedText *candidate = [[observation topCandidates:1] firstObject];
        if (candidate.string.length == 0) continue;
        AxsScreenOcrLine *line = [[AxsScreenOcrLine alloc] init];
        line.text = candidate.string;
        line.box = observation.boundingBox;
        [lines addObject:line];
    }
    // Vision 返回顺序不保证阅读顺序，按行（y 降序）再按列（x 升序）重排。
    [lines sortUsingComparator:^NSComparisonResult(AxsScreenOcrLine *left, AxsScreenOcrLine *right) {
        if (fabs(left.box.origin.y - right.box.origin.y) > 0.01) {
            return left.box.origin.y > right.box.origin.y ? NSOrderedAscending : NSOrderedDescending;
        }
        if (left.box.origin.x == right.box.origin.x) return NSOrderedSame;
        return left.box.origin.x < right.box.origin.x ? NSOrderedAscending : NSOrderedDescending;
    }];
    return lines;
}

NSArray<AxsScreenOcrLine *> *axs_screenocr_recognize_cgimage(CGImageRef image,
                                                             CGImagePropertyOrientation orientation,
                                                             NSError **error) {
    if (!image) {
        if (error) *error = axs_screenocr_error(30, @"截图数据无效");
        return nil;
    }

    NSError *requestError = nil;
    BOOL succeeded = NO;
    VNRecognizeTextRequest *request = nil;

    @try {
        VNImageRequestHandler *handler =
            [[VNImageRequestHandler alloc] initWithCGImage:image orientation:orientation options:@{}];
        request = axs_screenocr_make_request(VNRequestTextRecognitionLevelAccurate);
        succeeded = [handler performRequests:@[ request ] error:&requestError];
        if (!succeeded) {
            request = axs_screenocr_make_request(VNRequestTextRecognitionLevelFast);
            requestError = nil;
            succeeded = [handler performRequests:@[ request ] error:&requestError];
        }
    } @catch (NSException *exception) {
        if (error) *error = axs_screenocr_error(31, exception.reason ?: @"识别异常");
        axs_screenocr_log(@"in-process recognition threw: %@", exception.reason ?: @"(nil)");
        return nil;
    }

    if (!succeeded) {
        NSString *message = requestError.localizedDescription ?: @"识别失败";
        if (error) *error = axs_screenocr_error(32, message);
        axs_screenocr_log(@"in-process recognition failed: %@", message);
        return nil;
    }
    return axs_screenocr_lines_from_request(request);
}


NSString *axs_screenocr_helper_path(void) {
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

NSArray<AxsScreenOcrLine *> *axs_screenocr_recognize_image_at_path(NSString *imagePath,
                                                                   NSError **error) {
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
    // 只把 stdout 接进管道。stderr 留给 helper 自己处理（它已重定向到 /dev/null），
    // 否则框架日志会混进 JSON，把正常结果判定成「格式不正确」。
    posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDOUT_FILENO);
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

    id decoded = axs_screenocr_decode_payload(output);
    if (![decoded isKindOfClass:[NSDictionary class]]) {
        NSString *raw = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
        axs_screenocr_log(@"helper output invalid: %@", [raw substringToIndex:MIN(raw.length, 200)]);
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

