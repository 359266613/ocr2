//
//  OCRResultViewController.h
//  ScreenOCR
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface OCRResultViewController : UIViewController

/// 抓整屏 → 弹浮层 → 自动识别。window 传 nil 时自己找当前 key window。
+ (void)captureAndPresentFromWindow:(nullable UIWindow *)window;

/// 用指定图像弹浮层
+ (nullable instancetype)presentWithImage:(UIImage *)image hostWindow:(nullable UIWindow *)window;

/// 收起当前浮层（重新触发前调用，避免把结果页又截进去）
+ (void)dismissCurrentOverlay;

@end

NS_ASSUME_NONNULL_END
