//
//  OCRResultViewController.h
//  ScreenOCR
//

#import <UIKit/UIKit.h>

@interface OCRResultViewController : UIViewController

/// 抓整屏 → 弹浮层 → 自动识别
+ (void)captureAndPresentFromWindow:(UIWindow *)window;

/// 用指定图像弹浮层
+ (instancetype)presentWithImage:(UIImage *)image hostWindow:(UIWindow *)window;

@end
