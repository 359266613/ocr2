#pragma once

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// 一行识别结果。box 为 Vision 的归一化坐标，原点在左下角。
@interface AxsScreenOcrLine : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic) CGRect box;
@end

FOUNDATION_EXPORT NSString * _Nullable axs_screenocr_helper_path(void);

// 调用 /usr/libexec/AxsScreenOcrHelper 完成识别。
// 识别放在独立进程，避免在 SpringBoard 里加载 Vision 模型触发 safemode。
FOUNDATION_EXPORT NSArray<AxsScreenOcrLine *> * _Nullable
axs_screenocr_recognize_image_at_path(NSString *imagePath, NSError **error);

NS_ASSUME_NONNULL_END
