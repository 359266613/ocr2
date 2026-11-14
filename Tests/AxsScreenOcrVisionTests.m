#import "AxsScreenOcrVision.h"
#import <CoreText/CoreText.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

static void axs_screenocr_test_require(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static void axs_screenocr_test_languages(void) {
    NSArray *supported = @[@"en-US", @"fr-FR", @"zh-Hans", @"zh-Hant", @"yue-Hans", @"yue-Hant", @"ja-JP", @"ko-KR"];
    NSArray *cases = @[
        @[@[@"zh-Hans-CN"], @[@"zh-Hans", @"en-US"]],
        @[@[@"zh-Hant-TW"], @[@"zh-Hant", @"en-US"]],
        @[@[@"zh-TW"], @[@"zh-Hant", @"en-US"]],
        @[@[@"zh-HK"], @[@"zh-Hant", @"en-US"]],
        @[@[@"zh-MO"], @[@"zh-Hant", @"en-US"]],
        @[@[@"yue-Hant-HK"], @[@"zh-Hant", @"en-US"]],
        @[@[@"zh_Hans_CN"], @[@"zh-Hans", @"en-US"]],
        @[@[], @[@"zh-Hans", @"en-US"]],
        @[@[@"en-US", @"zh-Hant"], @[@"en-US"]],
        @[@[@"ja-JP", @"en-US"], @[@"ja-JP", @"en-US"]],
        @[@[@"fr-CA", @"ko-KR"], @[@"fr-FR", @"en-US"]],
    ];
    for (NSArray *item in cases) {
        BOOL chinese = NO;
        NSArray *actual = axs_screenocr_vision_languages(supported, item[0], &chinese);
        axs_screenocr_test_require([actual isEqualToArray:item[1]],
            [NSString stringWithFormat:@"languages preferred=%@ expected=%@ got=%@", item[0], item[1], actual]);
    }
    BOOL chinese = NO;
    NSArray *alias = axs_screenocr_vision_languages(@[@"en-GB", @"zh-CN", @"zh-TW"], @[@"zh-Hant"], &chinese);
    axs_screenocr_test_require(chinese && [alias isEqualToArray:@[@"zh-TW", @"en-GB"]], @"supported aliases");
    NSArray *missing = axs_screenocr_vision_languages(@[@"en-US"], @[@"zh-Hans"], &chinese);
    axs_screenocr_test_require([missing isEqualToArray:@[@"en-US"]], @"missing script is not invented");
    axs_screenocr_test_require([axs_screenocr_vision_languages(@[], @[], NULL) count] == 0, @"empty supported list");
}

static void axs_screenocr_test_errors(void) {
    NSError *underlying = [NSError errorWithDomain:@"test.model" code:-5
        userInfo:@{NSLocalizedDescriptionKey: @"network load failed"}];
    NSError *error = [NSError errorWithDomain:@"test.vision" code:9
        userInfo:@{NSLocalizedDescriptionKey: @"request failed", NSUnderlyingErrorKey: underlying}];
    NSString *description = axs_screenocr_vision_describe_error(error);
    axs_screenocr_test_require([description containsString:@"test.model/-5"] &&
        [description containsString:@"test.vision/9"], @"both error domains and codes retained");
    NSError *validation = nil;
    NSArray *lines = axs_screenocr_vision_recognize(NULL, kCGImagePropertyOrientationUp, NO,
        ^(__unused NSString *message) {}, &validation);
    axs_screenocr_test_require(lines == nil && validation != nil, @"invalid image fails explicitly");
}

static CGImageRef axs_screenocr_test_image(size_t height) CF_RETURNS_RETAINED {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, 1179, height, 8, 0, colorSpace, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);
    axs_screenocr_test_require(context != NULL, @"bitmap allocation");
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, 1179, height));
    CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica"), 64, NULL);
    NSDictionary *attributes = @{(__bridge NSString *)kCTFontAttributeName: (__bridge id)font};
    NSAttributedString *text = [[NSAttributedString alloc] initWithString:@"Apple Vision OCR 1234567890" attributes:attributes];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)text);
    CGContextSetRGBFillColor(context, 0, 0, 0, 1);
    CGContextSetTextPosition(context, 40, height - 150);
    CTLineDraw(line, context);
    CFRelease(line);
    CFRelease(font);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

// Explicit opt-in: model availability on a Mac does not validate an iPhone helper.
static void axs_screenocr_test_smoke(void) {
    CGImageRef image = axs_screenocr_test_image(2556);
    for (NSUInteger orientation = 1; orientation <= 8; orientation++) {
        NSError *error = nil;
        NSArray *lines = axs_screenocr_vision_recognize(image, (CGImagePropertyOrientation)orientation, YES,
            ^(NSString *message) { puts(message.UTF8String); }, &error);
        axs_screenocr_test_require(lines != nil, [NSString stringWithFormat:@"orientation=%lu %@",
            (unsigned long)orientation, axs_screenocr_vision_describe_error(error)]);
        if (orientation == 1) {
            NSString *text = [[lines valueForKey:@"text"] componentsJoinedByString:@" "];
            axs_screenocr_test_require([text containsString:@"1234567890"], @"real Vision smoke recognizes sample");
        }
        for (NSDictionary *item in lines) {
            double y = [item[@"y"] doubleValue], h = [item[@"h"] doubleValue];
            axs_screenocr_test_require(y >= -0.001 && y + h <= 1.001, @"mapped coordinates bounded");
        }
    }
    CGImageRelease(image);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        axs_screenocr_test_languages();
        axs_screenocr_test_errors();
        if (argc == 2 && strcmp(argv[1], "--smoke") == 0) axs_screenocr_test_smoke();
        puts("PASS: Vision policy and error tests");
    }
    return 0;
}
