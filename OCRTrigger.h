//
//  OCRTrigger.h
//  ScreenOCR
//
//  深链接触发：prefs:root=axsocr_recognize
//  GesturePro 的「预设链接」动作会调用 SpringBoard 私有的 applicationOpenURL:，
//  所以这里必须 hook 那个方法，光 hook UIApplication 的公开 API 收不到。
//

#pragma once

#import <Foundation/Foundation.h>

/// URL 是否是本插件的触发链接
BOOL OCRURLMatchesTrigger(NSURL *url);

/// 处理触发链接；返回 YES 表示已消费，不能再交给系统（否则会跳去设置）
BOOL OCRHandleTriggerURL(NSURL *url);

/// 收起当前结果浮层（在重新截图前调用，避免把上一次的结果截进去）
void OCRDismissOverlay(void);

/// 截图 + 识别 + 弹浮层。必须在主线程调用。
void OCRRunRecognition(void);
