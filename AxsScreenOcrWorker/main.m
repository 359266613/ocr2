#import "AxsScreenOcrWorkerDelegate.h"
#import "AxsScreenOcrPaths.h"
#import <stdio.h>

void axs_screenocr_worker_note(NSString *message) {
    fprintf(stderr, "%s\n", message.UTF8String ?: "");
    fflush(stderr);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *path = axs_screenocr_userLibraryPath(@"Logs/AxsScreenOcrWorker.log");
        NSFileManager *manager = NSFileManager.defaultManager;
        [manager createDirectoryAtPath:path.stringByDeletingLastPathComponent
          withIntermediateDirectories:YES attributes:nil error:NULL];
        if ([[manager attributesOfItemAtPath:path error:NULL][NSFileSize] unsignedLongLongValue] > 512 * 1024) {
            [manager removeItemAtPath:path error:NULL];
        }
        (void)freopen(path.fileSystemRepresentation, "a", stderr);
        axs_screenocr_worker_note([NSString stringWithFormat:@"--- UIKit worker start %@", NSDate.date]);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AxsScreenOcrWorkerDelegate.class));
    }
}
