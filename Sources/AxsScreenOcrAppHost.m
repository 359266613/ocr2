#import "AxsScreenOcrAppHost.h"
#import "AxsScreenOcrLog.h"
#import "AxsScreenOcrIPC.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <SpringBoardServices/SpringBoardServices.h>

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (void)openApplicationWithBundleID:(NSString *)identifier;
@end

NSString *axs_screenocr_front_application(void) {
    @try {
        // Theos leaves this Copy-owned return value unannotated.
        return CFBridgingRelease((__bridge CFStringRef)SBSCopyFrontmostApplicationDisplayIdentifier());
    } @catch (NSException *exception) {
        axs_screenocr_log(@"foreground lookup failed: %@", exception.reason ?: exception.name);
        return nil;
    }
}

void axs_screenocr_restore_application(NSString *identifier) {
    if (!identifier.length || [identifier isEqualToString:@"com.apple.springboard"] ||
        [identifier isEqualToString:AxsScreenOcrWorkerBundleIdentifier]) return;
    NSString *current = axs_screenocr_front_application();
    if (![current isEqualToString:AxsScreenOcrWorkerBundleIdentifier]) {
        axs_screenocr_log(@"worker restore skipped: foreground changed");
        return;
    }
    Class workspaceClass = objc_getClass("LSApplicationWorkspace");
    if (![workspaceClass respondsToSelector:@selector(defaultWorkspace)]) return;
    @try {
        LSApplicationWorkspace *workspace = [workspaceClass defaultWorkspace];
        if (![workspace respondsToSelector:@selector(openApplicationWithBundleID:)]) return;
        [workspace openApplicationWithBundleID:identifier];
        axs_screenocr_log(@"worker restore requested: %@", identifier);
    } @catch (NSException *exception) {
        axs_screenocr_log(@"worker restore failed: %@", exception.reason ?: exception.name);
    }
}
