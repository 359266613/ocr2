#import "AxsScreenOcrRootListController.h"
#import "AxsScreenOcrPreferences.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>


@interface AxsScreenOcrRootListController ()
@end

@implementation AxsScreenOcrRootListController

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *items = [[self loadSpecifiersFromPlistName:@"AxsScreenOcrRoot"
                                                           target:self] mutableCopy];
        [self axs_screenocr_addButton:@"测试触发一次识别"
                               action:@selector(axs_screenocr_test_trigger:) to:items];

        PSSpecifier *diagnostics = [PSSpecifier preferenceSpecifierNamed:@"排查"
                                     target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [diagnostics setProperty:@"触发后如果没有任何反应，查看 /var/mobile/Library/Logs/AxsScreenOcr.log。"
                       forKey:@"footerText"];
        [items addObject:diagnostics];

        [items addObject:[PSSpecifier preferenceSpecifierNamed:@"关于我们" target:self
                     set:nil get:nil detail:nil cell:PSGroupCell edit:nil]];
        [self axs_screenocr_addButton:@"Sileo 越狱源" action:@selector(axs_screenocr_openRepository:) to:items];
        [self axs_screenocr_addButton:@"TG分享频道" action:@selector(axs_screenocr_openTelegram:) to:items];
        [self axs_screenocr_addButton:@"QQ交流群组" action:@selector(axs_screenocr_openQQ:) to:items];
        _specifiers = items;
    }
    return _specifiers;
}

// 走和 GesturePro 完全相同的入口：由 SpringBoard 的 applicationOpenURL: 接管。
- (void)axs_screenocr_test_trigger:(id)sender {
    NSURL *url = [NSURL URLWithString:@"prefs:root=axsocr_recognize"];
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        if (!success) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"触发失败"
                message:@"系统拒绝了这条链接。请确认插件已启用并已注销桌面。"
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }];
}

- (void)axs_screenocr_addButton:(NSString *)title action:(SEL)action to:(NSMutableArray *)items {
    PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:title target:self
                          set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    item.buttonAction = action;
    [items addObject:item];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0) return nil;
    return axs_screenocr_readPreferences()[key] ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0) return;
    NSError *error = nil;
    if (!axs_screenocr_writePreference(key, value, &error)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"设置未保存"
            message:error.localizedDescription ?: @"请检查配置文件路径和写入权限。"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        [self reloadSpecifiers];
    }
}

- (void)axs_screenocr_openURL:(NSURL *)url fallback:(NSURL *)fallback {
    if (!url) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        if (success) return;
        if (fallback) {
            [self axs_screenocr_openURL:fallback fallback:nil];
        } else {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法打开链接"
                message:@"请确认已安装对应应用。" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }];
}

- (void)axs_screenocr_openRepository:(id)sender {
    NSString *source = @"https://axs66.github.io/pro";
    NSString *encoded = [source stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSURL *primary = [NSURL URLWithString:[@"sileo://source/" stringByAppendingString:encoded ?: source]];
    [self axs_screenocr_openURL:primary fallback:[NSURL URLWithString:source]];
}

- (void)axs_screenocr_openTelegram:(id)sender {
    [self axs_screenocr_openURL:[NSURL URLWithString:@"tg://resolve?domain=wxfx8"]
                   fallback:[NSURL URLWithString:@"https://t.me/wxfx8"]];
}

- (void)axs_screenocr_openQQ:(id)sender {
    [self axs_screenocr_openURL:[NSURL URLWithString:@"mqqapi://card/show_pslcard?src_type=internal&version=1&uin=678055716&card_type=group&source=qrcode"] fallback:nil];
}


@end
