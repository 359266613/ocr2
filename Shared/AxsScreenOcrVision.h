#pragma once

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^AxsScreenOcrVisionLogger)(NSString *message);

// Shared by the helper and the explicit Preferences diagnostic, never SpringBoard.
FOUNDATION_EXPORT NSArray<NSDictionary *> * _Nullable axs_screenocr_vision_recognize(
    CGImageRef _Nullable image, CGImagePropertyOrientation orientation, BOOL split,
    AxsScreenOcrVisionLogger logger, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSArray<NSString *> *axs_screenocr_vision_languages(
    NSArray<NSString *> *supported, NSArray<NSString *> *preferred, BOOL * _Nullable chinese);
FOUNDATION_EXPORT NSString *axs_screenocr_vision_describe_error(NSError * _Nullable error);
FOUNDATION_EXPORT NSString *axs_screenocr_vision_environment(void);

NS_ASSUME_NONNULL_END
