#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 落盘日志，方便真机排查插件到底有没有生效。
// 默认路径：/var/mobile/Library/Logs/AxsScreenOcr.log
FOUNDATION_EXPORT void axs_screenocr_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

NS_ASSUME_NONNULL_END
