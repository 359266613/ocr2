//
//  OCRGesture.h
//  ScreenOCR
//
//  给每个进程的 key window 挂一个「双指长按」手势
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface OCRGesture : NSObject

+ (instancetype)shared;

/// 幂等：同一个 window 只会挂一个手势
- (void)attachToWindow:(UIWindow *)window;

@end

NS_ASSUME_NONNULL_END
