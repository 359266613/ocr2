#import "AxsScreenOcrResultController.h"
#import "AxsScreenOcrCapture.h"
#import "AxsScreenOcrLog.h"

static UIWindow *axsScreenOcrOverlayWindow = nil;

@interface AxsScreenOcrResultController ()
@property (nonatomic, copy) NSString *recognizedText;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSTimer *statusTimer;
@end

@implementation AxsScreenOcrResultController

+ (void)axs_screenocr_present_text:(NSString *)text {
    if (axsScreenOcrOverlayWindow) {
        axs_screenocr_log(@"overlay already visible");
        return;
    }
    UIWindowScene *scene = axs_screenocr_active_window_scene();
    if (!scene) {
        axs_screenocr_log(@"overlay: no window scene");
        return;
    }

    AxsScreenOcrResultController *controller = [[AxsScreenOcrResultController alloc] init];
    controller.recognizedText = [text copy];

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelAlert + 20;
    window.backgroundColor = [UIColor clearColor];
    window.rootViewController = controller;

    axsScreenOcrOverlayWindow = window;
    [window makeKeyAndVisible];
    axs_screenocr_log(@"overlay presented, %lu chars", (unsigned long)text.length);
}

+ (void)axs_screenocr_dismiss_overlay {
    if (!axsScreenOcrOverlayWindow) return;
    [axsScreenOcrOverlayWindow setHidden:YES];
    axsScreenOcrOverlayWindow.rootViewController = nil;
    [axsScreenOcrOverlayWindow resignKeyWindow];
    axsScreenOcrOverlayWindow = nil;
}

+ (BOOL)axs_screenocr_is_presenting {
    return axsScreenOcrOverlayWindow != nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor systemBackgroundColor];
    card.layer.cornerRadius = 16.0;
    card.layer.masksToBounds = YES;
    [self.view addSubview:card];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"识别结果";
    title.font = [UIFont boldSystemFontOfSize:17.0];
    [card addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(axs_screenocr_close:)
    forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:close];

    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor separatorColor];
    [card addSubview:separator];

    UITextView *textView = [[UITextView alloc] init];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.text = self.recognizedText;
    textView.font = [UIFont systemFontOfSize:16.0];
    textView.textContainerInset = UIEdgeInsetsMake(8.0, 8.0, 8.0, 8.0);
    textView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    textView.layer.cornerRadius = 10.0;
    textView.alwaysBounceVertical = YES;
    self.textView = textView;
    [card addSubview:textView];

    UILabel *status = [[UILabel alloc] init];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.font = [UIFont systemFontOfSize:12.0];
    status.textColor = [UIColor secondaryLabelColor];
    status.text = [NSString stringWithFormat:@"共 %lu 字 · 可直接编辑后复制",
                   (unsigned long)self.recognizedText.length];
    self.statusLabel = status;
    [card addSubview:status];

    UIStackView *buttons = [[UIStackView alloc] init];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 8.0;
    buttons.distribution = UIStackViewDistributionFillEqually;
    [buttons addArrangedSubview:[self axs_screenocr_buttonWithTitle:@"复制"
                                                            action:@selector(axs_screenocr_copy:)]];
    [buttons addArrangedSubview:[self axs_screenocr_buttonWithTitle:@"全选"
                                                            action:@selector(axs_screenocr_select_all:)]];
    [buttons addArrangedSubview:[self axs_screenocr_buttonWithTitle:@"分享"
                                                            action:@selector(axs_screenocr_share:)]];
    [card addSubview:buttons];

    UILayoutGuide *margins = card.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12.0],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12.0],
        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [card.heightAnchor constraintEqualToAnchor:self.view.heightAnchor multiplier:0.7],

        [title.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [title.topAnchor constraintEqualToAnchor:margins.topAnchor constant:4.0],

        [close.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [close.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],

        [separator.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [separator.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10.0],
        [separator.heightAnchor constraintEqualToConstant:0.5],

        [textView.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [textView.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [textView.topAnchor constraintEqualToAnchor:separator.bottomAnchor constant:10.0],

        [status.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [status.topAnchor constraintEqualToAnchor:textView.bottomAnchor constant:8.0],

        [buttons.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [buttons.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [buttons.topAnchor constraintEqualToAnchor:status.bottomAnchor constant:8.0],
        [buttons.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor constant:-6.0],
        [buttons.heightAnchor constraintEqualToConstant:38.0],
    ]];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(axs_screenocr_end_editing:)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];
}

- (UIButton *)axs_screenocr_buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    [button setTitle:title forState:UIControlStateNormal];
    button.backgroundColor = [UIColor tertiarySystemFillColor];
    button.layer.cornerRadius = 10.0;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)axs_screenocr_show_status:(NSString *)status {
    [self.statusTimer invalidate];
    self.statusLabel.text = status;
    __weak typeof(self) weakSelf = self;
    self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:1.6 repeats:NO block:^(NSTimer *timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        strongSelf.statusLabel.text = [NSString stringWithFormat:@"共 %lu 字 · 可直接编辑后复制",
                                       (unsigned long)strongSelf.textView.text.length];
    }];
}

- (void)axs_screenocr_end_editing:(id)sender {
    [self.view endEditing:YES];
}

- (void)axs_screenocr_close:(id)sender {
    axs_screenocr_log(@"overlay closed by user");
    [AxsScreenOcrResultController axs_screenocr_dismiss_overlay];
}

- (void)axs_screenocr_copy:(id)sender {
    NSString *text = self.textView.text ?: @"";
    [UIPasteboard generalPasteboard].string = text;
    [self axs_screenocr_show_status:[NSString stringWithFormat:@"已复制 %lu 字",
                                     (unsigned long)text.length]];
}

- (void)axs_screenocr_select_all:(id)sender {
    [self.textView becomeFirstResponder];
    [self.textView selectAll:nil];
}

- (void)axs_screenocr_share:(id)sender {
    NSString *text = self.textView.text ?: @"";
    if (text.length == 0) return;
    UIActivityViewController *activity =
        [[UIActivityViewController alloc] initWithActivityItems:@[text] applicationActivities:nil];
    activity.popoverPresentationController.sourceView = (UIView *)sender;
    activity.popoverPresentationController.sourceRect = ((UIView *)sender).bounds;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.statusTimer invalidate];
    self.statusTimer = nil;
}

@end
