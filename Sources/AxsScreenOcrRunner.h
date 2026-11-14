#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AxsScreenOcrRunner : NSObject

// 主线程调用：抓图 -> 交给 helper 识别 -> 弹结果浮层。
+ (void)axs_screenocr_run;

@end

NS_ASSUME_NONNULL_END
