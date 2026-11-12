//
//  OCRResultViewController.m
//  ScreenOCR
//

#import "OCRResultViewController.h"
#import "OCRCapture.h"
#import "OCREngine.h"
#import "OCRConfig.h"

static UIWindow *gOCRWindow = nil;
static __weak UIWindow *gPreviousKeyWindow = nil;

#pragma mark - 框选遮罩

@interface OCRRegionView : UIView
@property (nonatomic, copy) void (^onFinish)(CGRect normalizedRect);
@property (nonatomic, copy) void (^onCancel)(void);
@end

@interface OCRRegionView ()
@end

@implementation OCRRegionView {
    CGPoint _startPoint;
    CGPoint _currentPoint;
    BOOL _hasSelection;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.multipleTouchEnabled = NO;

        UILabel *hint = [[UILabel alloc] init];
        hint.text = @"拖动框选要识别的区域";
        hint.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        hint.textColor = UIColor.whiteColor;
        hint.textAlignment = NSTextAlignmentCenter;
        hint.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:hint];

        [NSLayoutConstraint activateConstraints:@[
            [hint.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [hint.topAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor constant:24]
        ]];
    }
    return self;
}

- (CGRect)selectionRect {
    if (!_hasSelection) return CGRectZero;
    CGRect rect = CGRectMake(_startPoint.x, _startPoint.y,
                             _currentPoint.x - _startPoint.x,
                             _currentPoint.y - _startPoint.y);
    return CGRectIntersection(CGRectStandardize(rect), self.bounds);
}

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) return;

    CGContextSetFillColorWithColor(context, [UIColor colorWithWhite:0.0 alpha:0.45].CGColor);
    CGContextFillRect(context, self.bounds);

    CGRect selection = [self selectionRect];
    if (CGRectIsEmpty(selection)) return;

    // 挖空选区
    CGContextSetBlendMode(context, kCGBlendModeClear);
    CGContextFillRect(context, selection);
    CGContextSetBlendMode(context, kCGBlendModeNormal);

    // 虚线边框
    UIBezierPath *border = [UIBezierPath bezierPathWithRect:selection];
    CGFloat dashes[2] = { 6.0, 4.0 };
    [border setLineDash:dashes count:2 phase:0];
    border.lineWidth = 1.5;
    [[UIColor colorWithWhite:1.0 alpha:0.95] setStroke];
    [border stroke];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _startPoint = [touches.anyObject locationInView:self];
    _currentPoint = _startPoint;
    _hasSelection = YES;
    [self setNeedsDisplay];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _currentPoint = [touches.anyObject locationInView:self];
    [self setNeedsDisplay];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGRect selection = [self selectionRect];
    _hasSelection = NO;
    [self setNeedsDisplay];

    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    if (selection.size.width < 24 || selection.size.height < 24 || width <= 0 || height <= 0) {
        if (self.onCancel) self.onCancel();
        return;
    }

    CGRect normalized = CGRectMake(selection.origin.x / width,
                                   selection.origin.y / height,
                                   selection.size.width / width,
                                   selection.size.height / height);
    if (self.onFinish) self.onFinish(normalized);
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _hasSelection = NO;
    [self setNeedsDisplay];
    if (self.onCancel) self.onCancel();
}

@end

#pragma mark - 识别结果浮层

@interface OCRResultViewController () <UITextViewDelegate>
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIView *bottomBar;
@property (nonatomic, strong) NSLayoutConstraint *bottomBarBottom;
@property (nonatomic, assign) CGFloat keyboardHeight;
@property (nonatomic, assign) BOOL recognizing;
@end

@implementation OCRResultViewController

#pragma mark 生命周期

- (instancetype)initWithImage:(UIImage *)image {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _image = image;
        _keyboardHeight = 0;
        _recognizing = NO;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self buildUI];
    [self observeKeyboard];
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self updateBottomBarConstraint];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.image && self.textView.text.length == 0 && !self.recognizing) {
        [self runOCRWithImage:self.image];
    }
}

#pragma mark UI

- (void)buildUI {
    UILabel *title = [[UILabel alloc] init];
    title.text = @"OCR 文字识别";
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    close.tintColor = [UIColor tertiaryLabelColor];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close addTarget:self action:@selector(dismissOverlay) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.text = @"准备识别…";
    self.statusLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.statusLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.spinner];

    self.textView = [[UITextView alloc] init];
    self.textView.font = [UIFont systemFontOfSize:15];
    self.textView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.textView.layer.cornerRadius = 12;
    self.textView.layer.cornerCurve = kCACornerCurveContinuous;
    self.textView.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    self.textView.alwaysBounceVertical = YES;
    self.textView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.textView.delegate = self;
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.textView];

    self.bottomBar = [self buildBottomBar];
    [self.view addSubview:self.bottomBar];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    self.bottomBarBottom = [self.bottomBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-16];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:14],
        [title.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:18],

        [close.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [close.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [close.widthAnchor constraintEqualToConstant:30],
        [close.heightAnchor constraintEqualToConstant:30],

        [self.statusLabel.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor constant:-8],

        [self.spinner.centerYAnchor constraintEqualToAnchor:self.statusLabel.centerYAnchor],
        [self.spinner.leadingAnchor constraintEqualToAnchor:self.statusLabel.trailingAnchor constant:6],

        [self.textView.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:10],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [self.bottomBar.topAnchor constraintEqualToAnchor:self.textView.bottomAnchor constant:10],
        [self.bottomBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.bottomBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.bottomBar.heightAnchor constraintEqualToConstant:44],
        self.bottomBarBottom
    ]];
}

- (UIView *)buildBottomBar {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    [stack addArrangedSubview:[self buttonWithTitle:@"复制" action:@selector(copyText)]];
    [stack addArrangedSubview:[self buttonWithTitle:@"全选" action:@selector(selectAllText)]];
    [stack addArrangedSubview:[self buttonWithTitle:@"框选" action:@selector(startRegionSelection)]];
    [stack addArrangedSubview:[self buttonWithTitle:@"分享" action:@selector(shareText)]];

    return stack;
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [button setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    button.backgroundColor = [UIColor secondarySystemBackgroundColor];
    button.layer.cornerRadius = 10;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

#pragma mark 键盘

- (void)observeKeyboard {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillChangeFrame:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)keyboardWillChangeFrame:(NSNotification *)note {
    CGRect endFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect rectInView = [self.view convertRect:endFrame fromView:nil];
    CGFloat overlap = MAX(0.0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(rectInView));
    self.keyboardHeight = overlap;
    [self animateBottomBar];
}

- (void)keyboardWillHide:(NSNotification *)note {
    self.keyboardHeight = 0;
    [self animateBottomBar];
}

- (void)animateBottomBar {
    [self updateBottomBarConstraint];
    [UIView animateWithDuration:0.25
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
                         [self.view layoutIfNeeded];
                     }
                     completion:nil];
}

- (void)updateBottomBarConstraint {
    CGFloat inset = self.keyboardHeight > 0 ? self.keyboardHeight : self.view.safeAreaInsets.bottom;
    self.bottomBarBottom.constant = -(inset + 10);
}

#pragma mark 识别

- (void)runOCRWithImage:(UIImage *)image {
    if (self.recognizing) return;
    self.recognizing = YES;

    self.statusLabel.text = @"正在识别…";
    [self.spinner startAnimating];

    __weak typeof(self) weakSelf = self;
    [OCREngine recognizeImage:image
                    languages:OCRLanguages()
                     fastMode:NO
                   completion:^(NSString *text, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        strongSelf.recognizing = NO;
        [strongSelf.spinner stopAnimating];

        if (error) {
            strongSelf.statusLabel.text = [NSString stringWithFormat:@"识别失败：%@",
                                           error.localizedDescription ?: @"未知错误"];
            return;
        }

        strongSelf.textView.text = text ?: @"";
        if (text.length) {
            strongSelf.statusLabel.text = [NSString stringWithFormat:@"共 %lu 个字符",
                                           (unsigned long)text.length];
            [strongSelf toast:@"识别完成"];
        } else {
            strongSelf.statusLabel.text = @"未识别到文字";
            [strongSelf toast:@"没找到可识别的文字"];
        }
    }];
}

#pragma mark 操作

- (void)copyText {
    NSString *text = self.textView.text ?: @"";
    if (text.length == 0) {
        [self toast:@"没有可复制的内容"];
        return;
    }
    UIPasteboard.generalPasteboard.string = text;
    [self toast:@"已复制到剪贴板"];
}

- (void)selectAllText {
    if (self.textView.text.length == 0) {
        [self toast:@"没有内容"];
        return;
    }
    [self.textView becomeFirstResponder];
    [self.textView selectAll:nil];
}

- (void)shareText {
    NSString *text = self.textView.text ?: @"";
    if (text.length == 0) {
        [self toast:@"没有可分享的内容"];
        return;
    }

    UIActivityViewController *activity =
        [[UIActivityViewController alloc] initWithActivityItems:@[ text ] applicationActivities:nil];

    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad &&
        activity.popoverPresentationController) {
        activity.popoverPresentationController.sourceView = self.view;
        activity.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                                       CGRectGetMaxY(self.view.bounds) - 80,
                                                                       1, 1);
    }
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)startRegionSelection {
    [self.view endEditing:YES];

    OCRRegionView *regionView = [[OCRRegionView alloc] initWithFrame:self.view.bounds];
    regionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    __weak typeof(self) weakSelf = self;
    __weak typeof(regionView) weakRegionView = regionView;

    regionView.onFinish = ^(CGRect normalizedRect) {
        [weakRegionView removeFromSuperview];
        [weakSelf recognizeRegion:normalizedRect];
    };
    regionView.onCancel = ^{
        [weakRegionView removeFromSuperview];
    };

    [self.view addSubview:regionView];
}

- (void)recognizeRegion:(CGRect)normalizedRect {
    UIImage *cropped = OCRCropImage(self.image, normalizedRect);
    if (!cropped) {
        [self toast:@"选区无效"];
        return;
    }
    [self runOCRWithImage:cropped];
}

#pragma mark 关闭 / 提示

- (void)dismissOverlay {
    [self.view endEditing:YES];
    UIWindow *window = gOCRWindow;

    [UIView animateWithDuration:0.18
                     animations:^{
                         self.view.alpha = 0.0;
                     }
                     completion:^(BOOL finished) {
                         window.hidden = YES;
                         gOCRWindow = nil;
                         [gPreviousKeyWindow makeKeyWindow];
                     }];
}

- (void)toast:(NSString *)message {
    for (UIView *view in self.view.subviews) {
        if (view.tag == 0x0C0C) [view removeFromSuperview];
    }

    UILabel *label = [[UILabel alloc] init];
    label.tag = 0x0C0C;
    label.text = message;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.textColor = UIColor.whiteColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
    label.layer.cornerRadius = 12;
    label.layer.cornerCurve = kCACornerCurveContinuous;
    label.clipsToBounds = YES;
    label.alpha = 0.0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [label.bottomAnchor constraintEqualToAnchor:self.bottomBar.topAnchor constant:-14],
        [label.heightAnchor constraintEqualToConstant:34],
        [label.widthAnchor constraintGreaterThanOrEqualToConstant:120]
    ]];

    [UIView animateWithDuration:0.16
                     animations:^{
                         label.alpha = 1.0;
                     }
                     completion:^(BOOL finished) {
                         [UIView animateWithDuration:0.3
                                               delay:1.1
                                             options:UIViewAnimationOptionCurveEaseIn
                                          animations:^{
                                              label.alpha = 0.0;
                                          }
                                          completion:^(BOOL finished) {
                                              [label removeFromSuperview];
                                          }];
                     }];
}

#pragma mark - 入口

+ (void)captureAndPresentFromWindow:(UIWindow *)window {
    UIImage *image = OCRCaptureScreen();
    if (!image) {
        OCRLog(@"screen capture failed");
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"ScreenOCR"
                                                message:@"截屏失败，当前界面可能受系统保护"
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *presenter = window.rootViewController;
        if (presenter) [presenter presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self presentWithImage:image hostWindow:window];
}

+ (instancetype)presentWithImage:(UIImage *)image hostWindow:(UIWindow *)window {
    if (gOCRWindow) return nil;
    if (!image) return nil;

    gPreviousKeyWindow = window ?: OCRKeyWindow();

    OCRResultViewController *controller = [[OCRResultViewController alloc] initWithImage:image];

    UIWindow *overlay = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    if (@available(iOS 13.0, *)) {
        overlay.windowScene = window.windowScene ?: OCRKeyWindow().windowScene;
    }
    overlay.windowLevel = UIWindowLevelAlert + 20;
    overlay.backgroundColor = UIColor.clearColor;
    overlay.rootViewController = controller;
    gOCRWindow = overlay;

    [overlay makeKeyAndVisible];
    return controller;
}

@end
