#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// SpringBoard 主类。这里只声明插件实际调用 / hook 的 selector，
// 与 GesturePro 的「预设链接」动作走的是同一个入口（返回值为 void）。
@interface SpringBoard : UIApplication
- (void)applicationOpenURL:(id)url;
@end

// UIKit 私有整屏截图接口。用弱引用声明，系统移除符号时自动走兜底，
// 不会在 dylib 加载阶段因为找不到符号而崩溃。
extern UIImage *_Nullable _UICreateScreenUIImage(void) __attribute__((weak_import));
extern CGImageRef _Nullable UIGetScreenImage(void) __attribute__((weak_import));

NS_ASSUME_NONNULL_END
