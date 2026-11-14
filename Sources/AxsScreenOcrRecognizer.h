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

// This transport only launches the helper; it never executes Vision in its caller.
FOUNDATION_EXPORT NSArray<AxsScreenOcrLine *> * _Nullable
axs_screenocr_recognize_image_at_path(NSString *imagePath,
                                      CGImagePropertyOrientation orientation,
                                      NSError **error);

// Same transport, without segmentation, for the explicit host comparison.
FOUNDATION_EXPORT NSArray<AxsScreenOcrLine *> * _Nullable
axs_screenocr_recognize_single_image_at_path(NSString *imagePath, NSError **error);

NS_ASSUME_NONNULL_END

