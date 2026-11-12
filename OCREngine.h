//
//  OCREngine.h
//  ScreenOCR
//
//  Vision 文字识别封装：异步、按阅读顺序拼行
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^OCRTextCompletion)(NSString * _Nullable text, NSError * _Nullable error);

@interface OCREngine : NSObject

/// 使用默认语言 + 精确模式识别
+ (void)recognizeImage:(UIImage *)image completion:(OCRTextCompletion)completion;

/// languages 传 nil 表示交给系统自动判断（iOS 16+）或使用系统全部支持语言
+ (void)recognizeImage:(UIImage *)image
             languages:(nullable NSArray<NSString *> *)languages
              fastMode:(BOOL)fastMode
            completion:(OCRTextCompletion)completion;

@end

NS_ASSUME_NONNULL_END
