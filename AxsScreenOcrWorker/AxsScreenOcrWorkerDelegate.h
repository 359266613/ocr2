#pragma once

#import <UIKit/UIKit.h>

FOUNDATION_EXPORT void axs_screenocr_worker_note(NSString *message);

@interface AxsScreenOcrWorkerDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
