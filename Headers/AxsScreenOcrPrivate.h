#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// SpringBoard 主类。这里只声明插件实际调用 / hook 的 selector，
// 与 GesturePro 的「预设链接」动作走的是同一个入口（返回值为 void）。
@interface SpringBoard : UIApplication
- (void)applicationOpenURL:(id)url;
@end

NS_ASSUME_NONNULL_END
