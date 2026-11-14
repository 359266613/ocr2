#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AxsScreenOcrResultController : UIViewController

+ (void)axs_screenocr_present_text:(NSString *)text;
+ (void)axs_screenocr_dismiss_overlay;
+ (BOOL)axs_screenocr_is_presenting;

- (instancetype)axs_screenocr_initWithText:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
