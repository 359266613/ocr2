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

static VNRecognizeTextRequest *axs_screenocr_make_request(NSUInteger revision, BOOL cpuOnly) {
    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
    request.revision = revision;
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    request.usesLanguageCorrection = YES;
    request.recognitionLanguages = @[ @"zh-Hans", @"en-US" ];
    if (@available(iOS 16.0, *)) {
        request.automaticallyDetectsLanguage = NO;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    request.usesCPUOnly = cpuOnly;
#pragma clang diagnostic pop
    return request;
}

static void axs_screenocr_log_request(VNRecognizeTextRequest *request, NSString *name) {
    NSError *error = nil;
    NSArray *languages;
    if (@available(iOS 15.0, *)) {
        languages = [request supportedRecognitionLanguagesAndReturnError:&error];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        languages = [VNRecognizeTextRequest supportedRecognitionLanguagesForTextRecognitionLevel:request.recognitionLevel
                                                                                      revision:request.revision error:&error];
#pragma clang diagnostic pop
    }
    axs_screenocr_log(@"vision %@ revision=%lu level=accurate configured=%@ supported=%@ error=%@",
                      name, (unsigned long)request.revision,
                      [request.recognitionLanguages componentsJoinedByString:@","],
                      [languages componentsJoinedByString:@","] ?: @"unknown",
                      error.localizedDescription ?: @"none");
}

static void axs_screenocr_log_results(VNRecognizeTextRequest *request, NSString *name) {
    NSUInteger characters = 0, chinese = 0, invalid = 0, count = 0;
    double confidence = 0;
    for (VNRecognizedTextObservation *observation in request.results) {
        VNRecognizedText *candidate = [[observation topCandidates:1] firstObject];
        if (!candidate.string.length) continue;
        count++;
        confidence += candidate.confidence;
        characters += candidate.string.length;
        for (NSUInteger i = 0; i < candidate.string.length; i++) {
            unichar c = [candidate.string characterAtIndex:i];
            if ((c >= 0x3400 && c <= 0x9fff) || (c >= 0xf900 && c <= 0xfaff)) chinese++;
            if (c == 0xffff || c == 0xfffe || c == 0xfffd) invalid++;
        }
    }
    axs_screenocr_log(@"vision %@ result lines=%lu chars=%lu chinese=%lu invalid=%lu confidence=%.3f",
                      name, (unsigned long)count, (unsigned long)characters,
                      (unsigned long)chinese, (unsigned long)invalid,
                      count ? confidence / count : 0.0);
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

    NSError *lastError = nil;
    NSArray<AxsScreenOcrLine *> *emptyResult = nil;
    NSUInteger revisions[] = { VNRecognizeTextRequestRevision2, 0 };
    NSUInteger count = 1;
    if (@available(iOS 16.0, *)) {
        revisions[1] = VNRecognizeTextRequestRevision3;
        count = 2;
    }
    for (NSUInteger i = 0; i < count; i++) {
        for (NSUInteger backend = 0; backend < 2; backend++) {
            BOOL cpuOnly = backend == 1;
            NSString *name = [NSString stringWithFormat:@"r%lu-%@", (unsigned long)revisions[i],
                              cpuOnly ? @"cpu" : @"default"];
            @autoreleasepool {
                @try {
                    VNRecognizeTextRequest *request = axs_screenocr_make_request(revisions[i], cpuOnly);
                    axs_screenocr_log_request(request, name);
                    VNImageRequestHandler *handler =
                        [[VNImageRequestHandler alloc] initWithCGImage:image orientation:orientation options:@{}];
                    NSError *requestError = nil;
                    if ([handler performRequests:@[ request ] error:&requestError]) {
                        axs_screenocr_log_results(request, name);
                        NSArray<AxsScreenOcrLine *> *lines = axs_screenocr_lines_from_request(request);
                        if (lines.count) {
                            axs_screenocr_log(@"vision selected=%@", name);
                            return lines;
                        }
                        emptyResult = lines;
                        axs_screenocr_log(@"vision %@ returned no text", name);
                    } else {
                        lastError = requestError ?: axs_screenocr_error(32, @"Vision 未返回错误详情");
                        NSError *underlying = lastError.userInfo[NSUnderlyingErrorKey];
                        axs_screenocr_log(@"vision %@ failed: domain=%@ code=%ld message=%@ underlying=%@",
                                          name, lastError.domain, (long)lastError.code,
                                          lastError.localizedDescription, underlying ?: @"none");
                    }
                } @catch (NSException *exception) {
                    lastError = axs_screenocr_error(31, exception.reason ?: @"识别异常");
                    axs_screenocr_log(@"vision %@ threw: %@", name, exception.reason ?: @"unknown");
                }
            }
        }
    }
    if (emptyResult) return emptyResult;
    if (error) *error = lastError ?: axs_screenocr_error(32, @"识别失败");
    return nil;
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
    // 只把 stdout 接进管道。stderr 由 helper 写入独立日志，
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

