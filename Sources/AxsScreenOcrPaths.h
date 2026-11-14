#pragma once

#import <Foundation/Foundation.h>

#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
#else
#import <rootless.h>
#endif

static inline NSString *axs_screenocr_resourcePath(NSString *rootfsPath) {
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
    return jbroot(rootfsPath);
#else
    return ROOT_PATH_NS_VAR(rootfsPath);
#endif
}

static inline NSString *axs_screenocr_preferencesPath(void) {
    NSString *path = @"/var/mobile/Library/Preferences/com.axs.screenocr.plist";
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
    return jbroot(path);
#else
    // Mobile user preferences do not use the rootless installation prefix.
    return path;
#endif
}

// 运行期数据（日志、抓图临时文件）。这里不是安装资源，同样不套 rootless 前缀。
static inline NSString *axs_screenocr_userLibraryPath(NSString *relativePath) {
    NSString *path = [@"/var/mobile/Library" stringByAppendingPathComponent:relativePath];
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
    return jbroot(path);
#else
    return path;
#endif
}

static inline NSString *axs_screenocr_logPath(void) {
    return axs_screenocr_userLibraryPath(@"Logs/AxsScreenOcr.log");
}

static inline NSString *axs_screenocr_workDirectoryPath(void) {
    return axs_screenocr_userLibraryPath(@"Caches/AxsScreenOcr");
}
