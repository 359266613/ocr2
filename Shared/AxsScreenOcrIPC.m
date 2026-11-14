#import "AxsScreenOcrIPC.h"
#import "AxsScreenOcrPaths.h"
#import <math.h>

NSString * const AxsScreenOcrWorkerBundleIdentifier = @"com.axs.screenocr.worker";
NSString * const AxsScreenOcrWorkerURLScheme = @"axs-screenocr-worker";
const NSTimeInterval AxsScreenOcrJobTimeout = 60;
const NSUInteger AxsScreenOcrIPCMaxJSONBytes = 4 * 1024 * 1024;
const NSUInteger AxsScreenOcrIPCMaxImageBytes = 64 * 1024 * 1024;

static NSError *axs_screenocr_ipc_error(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.axs.screenocr.ipc" code:code
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *axs_screenocr_jobs_directory(void) {
    return axs_screenocr_userLibraryPath(@"Caches/AxsScreenOcrJobs");
}

NSString *axs_screenocr_job_directory(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class]) return nil;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:identifier];
    if (!uuid || ![uuid.UUIDString isEqualToString:identifier]) return nil;
    return [axs_screenocr_jobs_directory() stringByAppendingPathComponent:identifier];
}

static NSDictionary *axs_screenocr_ipc_attributes(BOOL directory) {
    return @{NSFileOwnerAccountID: @501, NSFileGroupOwnerAccountID: @501,
             NSFilePosixPermissions: directory ? @0700 : @0600};
}

static BOOL axs_screenocr_ipc_directory(NSString *path, NSError **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSDictionary *attributes = [manager attributesOfItemAtPath:path error:NULL];
    if (attributes && ![attributes[NSFileType] isEqualToString:NSFileTypeDirectory]) {
        if (error) *error = axs_screenocr_ipc_error(1, @"任务目录不是普通目录");
        return NO;
    }
    if (![manager createDirectoryAtPath:path withIntermediateDirectories:YES
                            attributes:axs_screenocr_ipc_attributes(YES) error:error]) return NO;
    return [manager setAttributes:axs_screenocr_ipc_attributes(YES) ofItemAtPath:path error:error];
}

BOOL axs_screenocr_ipc_write(NSDictionary *payload, NSString *path, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:error];
    if (!data) return NO;
    if (data.length > AxsScreenOcrIPCMaxJSONBytes) {
        if (error) *error = axs_screenocr_ipc_error(2, @"任务结果超过大小限制");
        return NO;
    }
    if (![data writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    return [NSFileManager.defaultManager setAttributes:axs_screenocr_ipc_attributes(NO)
                                         ofItemAtPath:path error:error];
}

NSDictionary *axs_screenocr_ipc_read(NSString *path, NSError **error) {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:error];
    if (!attributes) return nil;
    if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular] ||
        [attributes[NSFileOwnerAccountID] unsignedIntValue] != 501 ||
        [attributes[NSFileSize] unsignedLongLongValue] > AxsScreenOcrIPCMaxJSONBytes) {
        if (error) *error = axs_screenocr_ipc_error(3, @"任务文件类型、所有者或大小不正确");
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data || data.length > AxsScreenOcrIPCMaxJSONBytes) return nil;
    id payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![payload isKindOfClass:NSDictionary.class]) {
        if (error && !*error) *error = axs_screenocr_ipc_error(4, @"任务 JSON 不是对象");
        return nil;
    }
    return payload;
}

NSString *axs_screenocr_job_create(NSString *imagePath, CGImagePropertyOrientation orientation,
                                   BOOL split, NSError **error) {
    if (orientation < 1 || orientation > 8) {
        if (error) *error = axs_screenocr_ipc_error(5, @"截图方向无效");
        return nil;
    }
    NSFileManager *manager = NSFileManager.defaultManager;
    NSDictionary *imageAttributes = [manager attributesOfItemAtPath:imagePath error:error];
    if (!imageAttributes) return nil;
    if (![imageAttributes[NSFileType] isEqualToString:NSFileTypeRegular] ||
        [imageAttributes[NSFileSize] unsignedLongLongValue] > AxsScreenOcrIPCMaxImageBytes) {
        if (error) *error = axs_screenocr_ipc_error(6, @"截图文件类型或大小不正确");
        return nil;
    }
    if (!axs_screenocr_ipc_directory(axs_screenocr_jobs_directory(), error)) return nil;
    axs_screenocr_jobs_prune();
    NSString *identifier = NSUUID.UUID.UUIDString;
    NSString *directory = axs_screenocr_job_directory(identifier);
    if (!axs_screenocr_ipc_directory(directory, error)) return nil;
    NSString *input = [directory stringByAppendingPathComponent:@"input.png"];
    BOOL copied = [manager copyItemAtPath:imagePath toPath:input error:error]
        && [manager setAttributes:axs_screenocr_ipc_attributes(NO) ofItemAtPath:input error:error];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSDictionary *request = @{@"version": @1, @"id": identifier, @"orientation": @(orientation),
                             @"split": @(split), @"created": @(now), @"deadline": @(now + AxsScreenOcrJobTimeout)};
    if (!copied || !axs_screenocr_ipc_write(request,
        [directory stringByAppendingPathComponent:@"request.json"], error)) {
        axs_screenocr_job_remove(identifier);
        return nil;
    }
    return identifier;
}

NSDictionary *axs_screenocr_job_request(NSString *identifier, NSError **error) {
    NSString *directory = axs_screenocr_job_directory(identifier);
    NSDictionary *attributes = directory ? [NSFileManager.defaultManager attributesOfItemAtPath:directory error:error] : nil;
    if (!attributes || ![attributes[NSFileType] isEqualToString:NSFileTypeDirectory] ||
        [attributes[NSFileOwnerAccountID] unsignedIntValue] != 501) {
        if (error) *error = axs_screenocr_ipc_error(7, @"任务目录无效");
        return nil;
    }
    NSDictionary *request = axs_screenocr_ipc_read([directory stringByAppendingPathComponent:@"request.json"], error);
    if (!request) return nil;
    NSNumber *version = request[@"version"], *orientation = request[@"orientation"];
    NSNumber *split = request[@"split"], *created = request[@"created"], *deadline = request[@"deadline"];
    BOOL typesValid = [version isKindOfClass:NSNumber.class] && [orientation isKindOfClass:NSNumber.class]
        && [split isKindOfClass:NSNumber.class] && [created isKindOfClass:NSNumber.class]
        && [deadline isKindOfClass:NSNumber.class];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (!typesValid || ![request[@"id"] isEqual:identifier] || ![version isEqual:@1] ||
        orientation.doubleValue != orientation.integerValue || orientation.integerValue < 1 || orientation.integerValue > 8 ||
        split.doubleValue != split.integerValue || (split.integerValue != 0 && split.integerValue != 1) ||
        !isfinite(created.doubleValue) || !isfinite(deadline.doubleValue) ||
        created.doubleValue > now + 5 || deadline.doubleValue <= now ||
        deadline.doubleValue < created.doubleValue || deadline.doubleValue - created.doubleValue > AxsScreenOcrJobTimeout + 1) {
        if (error) *error = axs_screenocr_ipc_error(8, @"任务格式无效或已过期");
        return nil;
    }
    return request;
}

void axs_screenocr_job_remove(NSString *identifier) {
    NSString *path = axs_screenocr_job_directory(identifier);
    if (path) [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
}

void axs_screenocr_jobs_prune(void) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *base = axs_screenocr_jobs_directory();
    for (NSString *identifier in [manager contentsOfDirectoryAtPath:base error:NULL]) {
        NSString *path = axs_screenocr_job_directory(identifier);
        if (!path) continue;
        NSDictionary *attributes = [manager attributesOfItemAtPath:path error:NULL];
        NSDate *modified = attributes[NSFileModificationDate];
        if ([attributes[NSFileType] isEqualToString:NSFileTypeDirectory] &&
            [attributes[NSFileOwnerAccountID] unsignedIntValue] == 501 &&
            modified && -modified.timeIntervalSinceNow > 180) {
            axs_screenocr_job_remove(identifier);
        }
    }
}
