#pragma once

#import <Foundation/Foundation.h>

@interface AxsScreenOcrConfig : NSObject
+ (instancetype)axs_screenocr_shared;
- (BOOL)axs_screenocr_isEnabled;
- (id)axs_screenocr_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)axs_screenocr_reload;
@end
