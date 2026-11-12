//
//  OCRResultViewController.h
//  ScreenOCR
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface OCRResultViewController : UIViewController

/// 抓整屏 → 弹浮层 → 自动识别
+ (void)captureAndPresentFromWindow:(UIWindow *)window;

/// 用指定图像弹浮层
+ (instancetype)presentWithImage:(UIImage *)image hostWindow:(UIWindow *)window;

@end

NS_ASSUME_NONNULL_END
