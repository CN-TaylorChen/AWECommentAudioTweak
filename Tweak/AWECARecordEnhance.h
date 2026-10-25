// 录音转音色
// @cookieodd | github.com/cookieodd | t.me/cookieodd

#import <Foundation/Foundation.h>

#define kAWECAEnhanceEnabled @"AWECAEnhanceEnabled"
// 私聊转语音开关（默认跟随评论区：设置里可单独关闭）
#define kAWECAPrivateEnhanceEnabled @"AWECAPrivateEnhanceEnabled"
#define kAWECAStatusDotTag   19527
// 识别资源 ID（留空 = 默认 2.0 标准版 volc.seedasr.auc；1.0 历史版填 volc.bigasr.auc）
#define kAWECAASRResourceId  @"AWECAASRResourceId"

@interface AWECARecordEnhance : NSObject

+ (instancetype)shared;

@property (nonatomic, assign) BOOL enhanceEnabled;
// 私聊（IM）场景转语音开关，与评论区各自独立
@property (nonatomic, assign) BOOL privateEnhanceEnabled;
@property (nonatomic, assign, readonly) BOOL armed;
// 私聊录音进行中标记（与评论区 armed 相互独立）
@property (nonatomic, assign, readonly) BOOL privateArmed;
// 本次私聊录音产出文件的路径（录音器层完成时记下，发送时机使用）
@property (nonatomic, copy) NSString *privateRecordPath;
// 流水线已处理完，下一次发送回调直接放行（避免递归拦截）
@property (nonatomic, assign) BOOL privateSkipOnce;
// 最近一次「取消录制」的时间戳（NSDate reference 时间；0 = 从未取消或已开新录音）。
// 钩子用它识别「取消后紧跟的 DidFinishRecording 残留」——抖音取消时也会以 success:YES 回调。
// 这是状态标记而非时间窗口：取消后持续有效，直到下一次 markCommentTakeStarted 清零。
// 不用时间窗口的原因：主线程繁忙时取消的完成回调可能迟到任意久（实测可超 0.5s），窗口必漏
@property (nonatomic, assign, readonly) BOOL cancelledTake;

+ (BOOL)shouldShowStatusDot;
+ (void)refreshStatusDots;

- (void)armFromCommentButton;
- (void)markCommentTakeStarted;
- (void)markCommentTakeCancelled;

// 私聊场景：触摸按下/抬起/取消（cancelled 参数由抖音触摸事件直接给出，比评论区 clear 启发式更准）
- (void)markPrivateTakeStarted;
- (void)markPrivateTakeCancelled;

- (BOOL)shouldRunForCommentRecording;
// 私聊录音是否走增强（开关 + armed + 凭证齐备）
- (BOOL)shouldRunForPrivateRecording;
// 在发送时机同步等待流水线（私聊场景专用：发送前完成替换）
- (void)runPrivateEnhanceAtPath:(NSString *)path
                     completion:(void(^)(BOOL ok, NSString *message))completion;
// 该路径的流水线是否正在飞（用于发送时机判断要不要等待）
- (BOOL)isEnhancingPath:(NSString *)path;
- (void)resetPrivateTake;
- (BOOL)shouldSkipStickyReplaceForPath:(NSString *)path;

- (void)beginIfNeededAtPath:(NSString *)path;
- (void)waitForEnhancedPath:(NSString *)path
                 completion:(void(^)(BOOL ok, NSString *message))completion;

@end
