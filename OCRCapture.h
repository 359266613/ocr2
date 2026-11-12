//
//  OCRCapture.h
//  ScreenOCR
//
//  屏幕抓图 + 区域裁剪
//

#import <UIKit/UIKit.h>

/// 抓取整屏图像（含状态栏）。
/// 优先调用私有 _UICreateScreenUIImage()，失败时回退为渲染当前 key window。
UIImage * _Nullable OCRCaptureScreen(void);

/// 按归一化坐标（0~1，原点左上）从图像中裁出一块
UIImage * _Nullable OCRCropImage(UIImage *image, CGRect normalizedRect);

/// 取当前 key window（兼容多 scene）
UIWindow * _Nullable OCRKeyWindow(void);
