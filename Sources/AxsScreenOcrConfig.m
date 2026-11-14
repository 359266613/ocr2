#import "AxsScreenOcrConfig.h"
#import "AxsScreenOcrPreferences.h"

@interface AxsScreenOcrConfig ()
@property (atomic, copy) NSDictionary *snapshot;
@property (nonatomic, strong) dispatch_queue_t reloadQueue;
@end

static void axs_screenocr_preferencesDidChange(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object, CFDictionaryRef info) {
    AxsScreenOcrConfig *config = (__bridge AxsScreenOcrConfig *)observer;
    dispatch_async(config.reloadQueue, ^{
        [config axs_screenocr_reload];
    });
}

@implementation AxsScreenOcrConfig

+ (instancetype)axs_screenocr_shared {
    static AxsScreenOcrConfig *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _reloadQueue = dispatch_queue_create("com.axs.screenocr.preferences", DISPATCH_QUEUE_SERIAL);
        [self axs_screenocr_reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, axs_screenocr_preferencesDidChange,
            (__bridge CFStringRef)AxsScreenOcrPreferencesChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // Close the window between the first read and observer registration.
        dispatch_async(_reloadQueue, ^{ [self axs_screenocr_reload]; });
    }
    return self;
}

- (void)axs_screenocr_reload {
    self.snapshot = axs_screenocr_readPreferences();
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:AxsScreenOcrPreferencesChanged object:self];
    });
}

- (id)axs_screenocr_valueForKey:(NSString *)key defaultValue:(id)defaultValue {
    return self.snapshot[key] ?: defaultValue;
}

- (BOOL)axs_screenocr_isEnabled {
    id value = [self axs_screenocr_valueForKey:@"enabled" defaultValue:@(NO)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
