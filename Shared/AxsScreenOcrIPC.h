#pragma once

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const AxsScreenOcrWorkerBundleIdentifier;
FOUNDATION_EXPORT NSString * const AxsScreenOcrWorkerURLScheme;
FOUNDATION_EXPORT const NSTimeInterval AxsScreenOcrJobTimeout;
FOUNDATION_EXPORT const NSUInteger AxsScreenOcrIPCMaxJSONBytes;
FOUNDATION_EXPORT const NSUInteger AxsScreenOcrIPCMaxImageBytes;

FOUNDATION_EXPORT NSString * _Nullable axs_screenocr_job_directory(NSString *identifier);
FOUNDATION_EXPORT BOOL axs_screenocr_ipc_write(NSDictionary *payload, NSString *path,
                                              NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSDictionary * _Nullable axs_screenocr_ipc_read(NSString *path,
                                                                 NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSString * _Nullable axs_screenocr_job_create(NSString *imagePath,
    CGImagePropertyOrientation orientation, BOOL split, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSDictionary * _Nullable axs_screenocr_job_request(NSString *identifier,
                                                                    NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT void axs_screenocr_job_remove(NSString *identifier);
FOUNDATION_EXPORT void axs_screenocr_jobs_prune(void);

NS_ASSUME_NONNULL_END
