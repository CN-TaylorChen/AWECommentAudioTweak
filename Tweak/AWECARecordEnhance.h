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
// 本次私聊录音已被用户取消：在飞的流水线结束后绝不能再补发消息
// （否则取消过程中会同步发消息，弄乱抖音录音 UI，导致必须重进会话才能再录音）
@property (nonatomic, assign, readonly) BOOL privateAborted;
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

// ===== 私聊快照隔离（v1.4.6）=====
// 抖音私聊每条录音复用同一个文件路径。若流水线直接在该路径上转换（旧做法），
// 下一条录音按下时会出现：录音器打开的文件被插件删除/替换 -> 录音器启动失败卡 0 秒；
// 或补发发送的是"现在的路径内容"（下一条的录音）-> 消息错乱/丢失。
// 因此私聊流水线全程只操作「按下发送瞬间复制出来的独立副本」，抖音的活文件绝不触碰。
// 复制源路径 -> 副本路径 的映射由插件维护，begin/等待/重放共用同一份副本。
// 发送拦截时先复制快照并尽早起跑流水线（趁用户停在确认面板上）
- (void)privateBeginForSourcePath:(NSString *)sourcePath;
// 发送闸门同步等待：已有该源的快照则复用（流水线已在跑），否则补一份快照再等
- (void)privateWaitForSourcePath:(NSString *)sourcePath
                      completion:(void(^)(BOOL ok, NSString *message))completion;
// 该源路径当前对应的快照路径（尚未建快照时返回 nil）
- (NSString *)snapshotPathForSourcePath:(NSString *)sourcePath;
// 该路径是否已是插件自有的临时副本（aweca_im 目录）——是则无需再快照
+ (BOOL)isPluginOwnedPath:(NSString *)path;

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
