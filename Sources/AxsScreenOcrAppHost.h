#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Main-thread helpers, called before switching to the worker and after replying.
FOUNDATION_EXPORT NSString * _Nullable axs_screenocr_front_application(void);
FOUNDATION_EXPORT void axs_screenocr_restore_application(NSString * _Nullable identifier);

NS_ASSUME_NONNULL_END
