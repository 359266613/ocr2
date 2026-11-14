#pragma once

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

NS_ASSUME_NONNULL_BEGIN

// 一行识别结果。box 为 Vision 的归一化坐标，原点在左下角。
@interface AxsScreenOcrLine : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic) CGRect box;
@end

FOUNDATION_EXPORT NSString * _Nullable axs_screenocr_helper_path(void);

// 在 SpringBoard 进程内直接跑 Vision。
// Espresso 加载 OCR 模型依赖 ANE/GPU 后端，而这些权限只授予 App 与系统进程；
// 独立 helper 即使签了 platform-application，仍会报
// "Error loading network -5, -1" 并连带建不出 CVPixelBuffer。
FOUNDATION_EXPORT NSArray<AxsScreenOcrLine *> * _Nullable
axs_screenocr_recognize_cgimage(CGImageRef image,
                                CGImagePropertyOrientation orientation,
                                NSError **error);

// 兜底：调用 /usr/libexec/AxsScreenOcrHelper 完成识别。
FOUNDATION_EXPORT NSArray<AxsScreenOcrLine *> * _Nullable
axs_screenocr_recognize_image_at_path(NSString *imagePath, NSError **error);

NS_ASSUME_NONNULL_END

