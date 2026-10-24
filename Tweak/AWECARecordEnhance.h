// 录音转音色
// @cookieodd | github.com/cookieodd | t.me/cookieodd

#import <Foundation/Foundation.h>

#define kAWECAEnhanceEnabled @"AWECAEnhanceEnabled"
#define kAWECAStatusDotTag   19527
// 识别资源 ID（留空 = 默认 2.0 标准版 volc.seedasr.auc；1.0 历史版填 volc.bigasr.auc）
#define kAWECAASRResourceId  @"AWECAASRResourceId"

@interface AWECARecordEnhance : NSObject

+ (instancetype)shared;

@property (nonatomic, assign) BOOL enhanceEnabled;
@property (nonatomic, assign, readonly) BOOL armed;
// 最近一次「取消录制」的时间戳（NSDate reference 时间；0 = 从未取消或已开新录音）。
// 钩子用它识别「取消后紧跟的 DidFinishRecording 残留」——抖音取消时也会以 success:YES 回调
@property (nonatomic, assign, readonly) NSTimeInterval lastCancelAt;

+ (BOOL)shouldShowStatusDot;
+ (void)refreshStatusDots;

- (void)armFromCommentButton;
- (void)markCommentTakeStarted;
- (void)markCommentTakeCancelled;

- (BOOL)shouldRunForCommentRecording;
- (BOOL)shouldSkipStickyReplaceForPath:(NSString *)path;

- (void)beginIfNeededAtPath:(NSString *)path;
- (void)waitForEnhancedPath:(NSString *)path
                 completion:(void(^)(BOOL ok, NSString *message))completion;

@end
