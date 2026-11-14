#import "AxsScreenOcrAppHost.h"
#import "AxsScreenOcrLog.h"
#import "AxsScreenOcrIPC.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <SpringBoardServices/SpringBoardServices.h>

@protocol AxsScreenOcrApplicationIdentity <NSObject>
- (NSString *)bundleIdentifier;
@end

@interface UIApplication (AxsScreenOcrForeground)
- (id<AxsScreenOcrApplicationIdentity>)_accessibilityFrontMostApplication;
- (id<AxsScreenOcrApplicationIdentity>)frontMostApplication;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (void)openApplicationWithBundleID:(NSString *)identifier;
@end

NSString *axs_screenocr_front_application(void) {
    if (!NSThread.isMainThread) return nil;
    @try {
        if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            // SBS is a synchronous client of SpringBoard; never call it from its own main thread.
            UIApplication *springBoard = UIApplication.sharedApplication;
            id<AxsScreenOcrApplicationIdentity> front = nil;
            if ([springBoard respondsToSelector:@selector(_accessibilityFrontMostApplication)]) {
                front = [springBoard _accessibilityFrontMostApplication];
            }
            if (!front && [springBoard respondsToSelector:@selector(frontMostApplication)]) {
                front = [springBoard frontMostApplication];
            }
            if (![front respondsToSelector:@selector(bundleIdentifier)]) return nil;
            NSString *identifier = [front bundleIdentifier];
            return [identifier isKindOfClass:NSString.class] ? [identifier copy] : nil;
        }
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
