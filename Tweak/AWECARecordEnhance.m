// 录音转音色
// @cookieodd | github.com/cookieodd | t.me/cookieodd

#import "AWECARecordEnhance.h"
#import "AWECATTSManager.h"
#import "AWECAAudioReplacer.h"
#import "AWECAUtils.h"
#import "AWECATOSUploader.h"
#import <UIKit/UIKit.h>

// 录音文件识别标准版：submit 提交 + query 轮询（两段式异步）
// 标准版只收公网音频 URL，本地录音需先经 TOS 上传（见 AWECATOSUploader）
// 文档：https://www.volcengine.com/docs/6561/1354868
#define kASRSubmitURL         @"https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit"
#define kASRQueryURL          @"https://openspeech.bytedance.com/api/v3/auc/bigmodel/query"
#define kASRDefaultResourceId @"volc.seedasr.auc"   // 2.0 标准版；1.0 历史版为 volc.bigasr.auc
#define kEnhanceTimeout       120.0                 // 上传+排队+识别整体超时
#define kASRQueryInterval     3.0                   // query 轮询间隔（秒）
#define kASRMaxQueryRounds    30                    // 最多轮询 30 次（约 90 秒）
#define kASRSubmitRetries     2                     // submit 网络失败重试次数

static NSString *AWECAASRTrim(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return @"";
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *AWECAASRHeader(NSDictionary *headers, NSString *key) {
    id v = headers[key];
    if (!v) {
        for (NSString *k in headers) {
            if ([k caseInsensitiveCompare:key] == NSOrderedSame) { v = headers[k]; break; }
        }
    }
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v respondsToSelector:@selector(stringValue)]) return [v stringValue];
    return nil;
}

static NSString *AWECAASRCodeHint(NSString *code) {
    if ([code isEqualToString:@"45000030"]) return @"标准版识别未开通：火山控制台「服务管理」→ 录音文件识别 → 开通标准版资源（volc.seedasr.auc / volc.bigasr.auc）。极速版已不开放，勿再选极速版";
    if ([code isEqualToString:@"45000001"]) return @"请求参数无效（可能是音频 URL 无法下载或格式不支持）";
    if ([code isEqualToString:@"45000002"]) return @"空音频";
    if ([code isEqualToString:@"45000151"]) return @"音频格式不正确";
    if ([code isEqualToString:@"45000132"]) return @"音频超过大小限制";
    if ([code isEqualToString:@"55000031"]) return @"服务器繁忙，请稍后重试";
    return nil;
}

@interface AWECARecordEnhance ()
@property (nonatomic, assign) BOOL armed;
@property (nonatomic, assign) BOOL privateArmed;   // 私聊录音进行中标记（与评论区 armed 相互独立）
@property (nonatomic, assign, readwrite) BOOL privateAborted; // 私聊本次录音已取消：在飞流水线结束后不得补发消息
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, copy) NSString *inFlightPath;
@property (nonatomic, copy) NSString *inFlightStamp;    // 流水线启动时目标文件的指纹，防止覆盖已被改动的文件
@property (nonatomic, copy) NSString *lastEnhancedPath;
@property (nonatomic, copy) NSString *lastEnhancedStamp; // 成功结果对应的文件指纹，路径复用时不误命中缓存
@property (nonatomic, copy) NSString *lastFailedPath;
@property (nonatomic, copy) NSString *lastFailedStamp;
@property (nonatomic, copy) NSString *lastMessage;
@property (nonatomic, strong) NSMutableArray *waiters;   // 元素：@{@"path": 路径, @"block": completion}
@property (nonatomic, assign) BOOL finishedOnce;
@property (nonatomic, assign) NSUInteger pipelineEpoch;
@property (nonatomic, assign) BOOL cancelledTake; // 取消后待消费的残留标记，供钩子识别取消的 DidFinishRecording
// 私聊快照隔离：源路径(抖音复用的活文件) -> 副本路径(插件私有副本)
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *snapMap;
// 当前在飞流水线对应的源路径（取消精确作废用：只有取消的是"这一条"才作废流水线）
@property (nonatomic, copy) NSString *inFlightSourcePath;
// 已被用户取消、尚未等到结果的排队 waiter 的流水线路径（按路径精确取消，不再用全局 abort 串台）
@property (nonatomic, strong) NSMutableSet<NSString *> *abortedWaiterPaths;
@end

@implementation AWECARecordEnhance

+ (instancetype)shared {
    static AWECARecordEnhance *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[AWECARecordEnhance alloc] init];
        inst.waiters = [NSMutableArray array];
        inst.snapMap = [NSMutableDictionary dictionary];
        inst.abortedWaiterPaths = [NSMutableSet set];
        inst->_enhanceEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:kAWECAEnhanceEnabled];
        // 私聊开关默认跟随评论区（未设置过时取评论区值）
        if ([[NSUserDefaults standardUserDefaults] objectForKey:kAWECAPrivateEnhanceEnabled] == nil) {
            inst->_privateEnhanceEnabled = inst->_enhanceEnabled;
        } else {
            inst->_privateEnhanceEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:kAWECAPrivateEnhanceEnabled];
        }
    });
    return inst;
}

+ (BOOL)shouldShowStatusDot {
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    return [AWECAAudioReplacer shared].enabled || enhance.enhanceEnabled || enhance.privateEnhanceEnabled;
}

- (void)setEnhanceEnabled:(BOOL)enhanceEnabled {
    if (_enhanceEnabled == enhanceEnabled) return;
    _enhanceEnabled = enhanceEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:enhanceEnabled forKey:kAWECAEnhanceEnabled];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [AWECARecordEnhance refreshStatusDots];
}

- (void)setPrivateEnhanceEnabled:(BOOL)privateEnhanceEnabled {
    if (_privateEnhanceEnabled == privateEnhanceEnabled) return;
    _privateEnhanceEnabled = privateEnhanceEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:privateEnhanceEnabled forKey:kAWECAPrivateEnhanceEnabled];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [AWECARecordEnhance refreshStatusDots];
}

static void AWECAWalkHideStatusDots(UIView *v, BOOL hide) {
    if (v.tag == kAWECAStatusDotTag) v.hidden = hide;
    for (UIView *s in v.subviews) AWECAWalkHideStatusDots(s, hide);
}

+ (void)refreshStatusDots {
    BOOL hide = ![self shouldShowStatusDot];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) AWECAWalkHideStatusDots(w, hide);
    }
}

- (void)armFromCommentButton {
    self.armed = YES;
}

- (void)markCommentTakeStarted {
    self.armed = YES;
    self.cancelledTake = NO; // 新录音开始，此前的取消不再相关
}

- (void)markCommentTakeCancelled {
    self.armed = NO;
    // 状态标记（非时间窗口）：取消后任何迟到的 DidFinishRecording 都是这一遍的残留，
    // 直到下次 markCommentTakeStarted 才放行——主线程忙时完成回调可能迟到任意久
    self.cancelledTake = YES;
    // 取消时必须作废在飞流水线：否则取消的录音会白跑上传+识别+合成，
    // 其结果（成功/失败）还会写入路径缓存，导致抖音复用同一路径时后续录音全部假提示
    [self invalidatePipeline:@"已取消，保留原声"];
}

// 私聊场景：armed 独立于评论区，取消作废逻辑完全复用（评论区与私聊 UI 互斥，同一时刻只会有一个在录音）
- (void)markPrivateTakeStarted {
    self.privateArmed = YES;
    self.privateRecordPath = nil;
    self.privateSkipOnce = NO;
    self.privateAborted = NO;
}

- (void)markPrivateTakeCancelled {
    self.privateArmed = NO;
    NSString *cancelledPath = self.privateRecordPath;
    self.privateRecordPath = nil;
    // 先置取消标记再作废流水线：作废会同步 flush waiter（gate 回调），回调里凭此标记拒绝补发消息，
    // 避免「取消过程中同步发消息」把抖音录音 UI 状态弄乱（表现为必须重进会话才能再录音）
    self.privateAborted = YES;
    // v1.4.6 精确作废：只有取消的正是「在飞流水线对应的那一条」才作废。
    // 旧做法无条件 invalidatePipeline：下一条录音的按下/取消会误杀上一条还在跑的流水线
    // （其 gate 回调被"已取消"拒绝 -> 上一条消息被静默丢弃），也会把 privateAborted 串给新任务
    if (cancelledPath.length && self.inFlightSourcePath.length &&
        [self.inFlightSourcePath isEqualToString:cancelledPath]) {
        [self invalidatePipeline:@"已取消，保留原声"];
    } else if (cancelledPath.length) {
        // 排队中的那条被取消：标记其快照路径，flush 时以"已取消"唤醒（不重放、不误伤别条）
        NSString *snap = self.snapMap[cancelledPath];
        if (snap.length) {
            for (NSDictionary *entry in self.waiters) {
                if ([entry[@"path"] isEqualToString:snap]) {
                    [self.abortedWaiterPaths addObject:snap];
                    break;
                }
            }
        }
    }
    // 快照映射定期修剪：只留最近 8 条，防止长时间聊天内存缓慢增长
    while (self.snapMap.count > 8) {
        NSString *first = self.snapMap.allKeys.firstObject;
        [self.snapMap removeObjectForKey:first];
    }
}

// 作废当前流水线：epoch++ 使所有迟到回调被防护挡下（不 install、不写缓存、不假 toast）
- (void)invalidatePipeline:(NSString *)message {
    if (!self.busy) return;
    self.pipelineEpoch += 1;
    self.finishedOnce = YES;
    self.busy = NO;
    self.inFlightSourcePath = nil;
    NSString *p = self.inFlightPath; // 先保存再清空：flush 时让路径匹配的 waiter 收到取消消息（而非"任务冲突"）
    self.inFlightPath = nil;
    self.inFlightStamp = nil;
    self.lastMessage = message;
    [self flushWaitersOk:NO path:p message:message];
}

// 文件指纹：size + 修改时间。抖音取消后重录常复用同一路径，仅靠路径判断会把旧结果错判给新文件
- (NSString *)fileStampForPath:(NSString *)path {
    if (!path.length) return nil;
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!attr) return nil;
    return [NSString stringWithFormat:@"%llu|%@",
            (unsigned long long)attr.fileSize, attr.fileModificationDate];
}

- (BOOL)hasVolcanoCredentials {
    AWECATTSManager *mgr = [AWECATTSManager shared];
    return mgr.accessToken.length > 0 || mgr.appID.length > 0;
}

- (BOOL)shouldRunForCommentRecording {
    return self.enhanceEnabled && self.armed && [self hasVolcanoCredentials];
}

- (BOOL)shouldRunForPrivateRecording {
    BOOL ok = self.privateEnhanceEnabled && self.privateArmed && self.privateRecordPath.length && [self hasVolcanoCredentials];
    NSLog(@"AWECA-IM: shouldRun enabled=%d armed=%d pathLen=%lu cred=%d -> %d",
          self.privateEnhanceEnabled, self.privateArmed,
          (unsigned long)self.privateRecordPath.length, [self hasVolcanoCredentials], ok);
    return ok;
}

// 私聊发送时机：跑完整流水线（TOS上传→ASR→TTS→替换），完成后回调才有结果可发
- (void)runPrivateEnhanceAtPath:(NSString *)path
                     completion:(void(^)(BOOL ok, NSString *message))completion {
    [self waitForEnhancedPath:path completion:completion];
}

- (BOOL)isEnhancingPath:(NSString *)path {
    if (!self.busy || !path.length) return NO;
    return [self.inFlightPath isEqualToString:path];
}

- (void)resetPrivateTake {
    self.privateArmed = NO;
    self.privateRecordPath = nil;
    self.privateSkipOnce = NO; // 防御性：任何收尾都不得让 skip 卡在 YES（否则下一条消息被误放行为原声）
}

- (BOOL)shouldSkipStickyReplaceForPath:(NSString *)path {
    if (self.busy) return YES;
    if (self.enhanceEnabled && self.armed) return YES;
    if (path.length && [self.lastEnhancedPath isEqualToString:path]) return YES;
    if (path.length && [self.lastFailedPath isEqualToString:path]) return YES;
    return NO;
}

- (void)beginIfNeededAtPath:(NSString *)path {
    [self waitForEnhancedPath:path completion:nil];
}

#pragma mark - 私聊快照隔离（v1.4.6）

+ (BOOL)isPluginOwnedPath:(NSString *)path {
    return path.length > 0 && [path containsString:@"/aweca_im/"];
}

// 把源文件复制成插件私有副本（保留扩展名；副本彼此唯一，永不复用）
- (NSString *)aweca_makeSnapshotOfSourcePath:(NSString *)src {
    if (!src.length) return nil;
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:src error:nil];
    if (!attr || attr.fileSize == 0) return nil;   // 源文件不存在/为空（取消残留）——不建快照
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"aweca_im"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    static dispatch_once_t onceToken;
    static NSString *bootTag;
    dispatch_once(&onceToken, ^{ bootTag = [NSString stringWithFormat:@"%d", arc4random()]; });
    NSString *snap = [dir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"snap_%@_%u%@",
         bootTag, arc4random(), src.pathExtension.length ? [@"." stringByAppendingString:src.pathExtension] : @""]];
    NSError *err = nil;
    if (![[NSFileManager defaultManager] copyItemAtPath:src toPath:snap error:&err]) {
        NSLog(@"AWECA-IM: snapshot copy failed %@ -> %@ err=%@", src, snap, err);
        return nil;
    }
    NSLog(@"AWECA-IM: snapshot %@ -> %@", src, snap);
    return snap;
}

// 源路径 -> 快照路径（已有映射则复用，流水线已在副本上跑；否则补一份快照）
- (NSString *)aweca_snapshotForSourcePath:(NSString *)src {
    if (![AWECARecordEnhance isPluginOwnedPath:src]) {
        NSString *existing = self.snapMap[src];
        if (existing.length) return existing;
        NSString *snap = [self aweca_makeSnapshotOfSourcePath:src];
        if (snap.length) self.snapMap[src] = snap;
        return snap;
    }
    return src;   // 本来就是插件自有副本（Format 架构落盘的临时文件），直接用
}

- (void)privateBeginForSourcePath:(NSString *)sourcePath {
    if (!sourcePath.length) return;
    NSString *snap = [self aweca_snapshotForSourcePath:sourcePath];
    if (!snap.length) return;
    if (!self.busy) self.inFlightSourcePath = sourcePath;
    [self waitForEnhancedPath:snap completion:nil];
}

- (void)privateWaitForSourcePath:(NSString *)sourcePath
                      completion:(void(^)(BOOL ok, NSString *message))completion {
    if (!sourcePath.length) {
        if (completion) completion(NO, nil);
        return;
    }
    NSString *snap = [self aweca_snapshotForSourcePath:sourcePath];
    if (!snap.length) {
        // 快照失败 = 源文件已不在（取消残留/被清掉）：不跑流水线、不重放
        if (completion) completion(NO, @"录音文件不存在，已取消发送");
        return;
    }
    if (!self.busy) self.inFlightSourcePath = sourcePath;
    [self waitForEnhancedPath:snap completion:completion];
}

- (NSString *)snapshotPathForSourcePath:(NSString *)sourcePath {
    if ([AWECARecordEnhance isPluginOwnedPath:sourcePath]) return sourcePath;
    return self.snapMap[sourcePath];
}

- (void)waitForEnhancedPath:(NSString *)path
                 completion:(void(^)(BOOL ok, NSString *message))completion {
    if (!path.length) {
        if (completion) completion(NO, nil);
        return;
    }
    // 文件不存在或为空（抖音取消时已删除/截断录音文件）：不启动流水线、不写缓存、不报错。
    // 这是取消场景的兜底——即使取消残留标记因"取消后极速重录"被提前清零，也绝不会去读已删的文件
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!attr || attr.fileSize == 0) {
        if (completion) completion(NO, nil);
        return;
    }
    // 结果缓存早退：必须同时校验文件指纹，防止抖音复用同一路径时把旧结果错发给新录音
    NSString *stamp = [self fileStampForPath:path];
    if (!self.busy && stamp.length && self.lastEnhancedPath.length &&
        [self.lastEnhancedPath isEqualToString:path] && [self.lastEnhancedStamp isEqualToString:stamp]) {
        if (completion) completion(YES, self.lastMessage);
        return;
    }
    if (!self.busy && self.lastFailedPath.length &&
        [self.lastFailedPath isEqualToString:path] && [self.lastFailedStamp isEqualToString:stamp]) {
        if (completion) completion(NO, self.lastMessage);
        return;
    }
    if (completion) {
        [self.waiters addObject:@{ @"path": path, @"block": [completion copy] }];
    }
    if (self.busy) return;
    [self startPipelineAtPath:path];
}

// 只唤醒路径匹配的等待者；不匹配的（排队中的下一条）不再当冲突丢弃——
// 快照化后每条录音的流水线路径彼此不同，旧做法会把下一条误判成冲突。
// 正确行为：流水线结束后自动起跑队列中下一条的流水线，其 waiter 继续等待。
// 用户已取消的那条（abortedWaiterPaths 命中）以"已取消"唤醒，绝不重放。
- (void)flushWaitersOk:(BOOL)ok path:(NSString *)path message:(NSString *)msg {
    NSArray *list = [self.waiters copy];
    [self.waiters removeAllObjects];
    NSMutableArray *queued = [NSMutableArray array];
    for (NSDictionary *entry in list) {
        void (^cb)(BOOL, NSString *) = entry[@"block"];
        NSString *wPath = entry[@"path"];
        // 逐个异常隔离：单个 waiter 回调抛异常（如回调里消息发到已析构对象）绝不能向上冒泡——
        // 否则会打断调用方（取消钩子里 %orig 还没执行，抖音原生录音状态就卡死）
        @try {
            if (path.length > 0 && [wPath isEqualToString:path]) {
                [self.abortedWaiterPaths removeObject:wPath];
                cb(ok, msg);
            } else if ([self.abortedWaiterPaths containsObject:wPath]) {
                [self.abortedWaiterPaths removeObject:wPath];
                cb(NO, @"已取消，保留原声");
            } else {
                [queued addObject:entry];
            }
        } @catch (NSException *e) {
            NSLog(@"AWECA-IM: waiter exception swallowed: %@", e);
        }
    }
    self.waiters = queued;
    // 队列不为空且流水线已空闲：起跑下一条（其 waiter 留在队列里等完成回调）
    if (queued.count > 0 && !self.busy) {
        NSString *next = queued[0][@"path"];
        if (next.length) [self startPipelineAtPath:next];
    }
}

- (void)finishPipelineOk:(BOOL)ok path:(NSString *)path message:(NSString *)msg {
    if (self.finishedOnce) return;
    self.finishedOnce = YES;
    self.pipelineEpoch += 1;
    self.busy = NO;
    self.inFlightPath = nil;
    self.inFlightStamp = nil;
    self.inFlightSourcePath = nil;
    self.lastMessage = msg;
    NSString *stamp = [self fileStampForPath:path];
    if (ok && stamp.length) {
        self.lastEnhancedPath = path;
        self.lastEnhancedStamp = stamp;
        self.lastFailedPath = nil;
        self.lastFailedStamp = nil;
    } else {
        self.lastFailedPath = path;
        self.lastFailedStamp = stamp; // stamp 为 nil（文件已不在）时不会命中早退，允许下次重试
        if (ok) {
            self.lastEnhancedPath = nil;
            self.lastEnhancedStamp = nil;
        }
    }
    [self flushWaitersOk:ok path:path message:msg];
}

- (void)startPipelineAtPath:(NSString *)path {
    self.busy = YES;
    self.finishedOnce = NO;
    self.inFlightPath = path;
    self.inFlightStamp = [self fileStampForPath:path];
    self.lastFailedPath = nil;
    self.lastFailedStamp = nil;
    NSUInteger epoch = ++self.pipelineEpoch;

    [AWECAUtils showToast:@"识别合成中..." duration:2.0];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kEnhanceTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.pipelineEpoch != epoch) return;
        [weakSelf finishPipelineOk:NO path:path message:@"识别合成超时，已保留原声"];
    });

    [self recognizeAudioAtPath:path completion:^(NSString *text, NSString *error) {
        if (weakSelf.finishedOnce || weakSelf.pipelineEpoch != epoch) return;
        if (!text.length) {
            [weakSelf finishPipelineOk:NO path:path message:error.length ? error : @"识别失败，已保留原声"];
            return;
        }
        [AWECAUtils showToast:@"正在合成..." duration:2.0];
        [[AWECATTSManager shared] synthesizeVolcanoPreviewText:text completion:^(BOOL success, NSString *audioPath, NSString *ttsError) {
            if (weakSelf.finishedOnce || weakSelf.pipelineEpoch != epoch) return;
            if (!success || !audioPath.length) {
                [weakSelf finishPipelineOk:NO path:path message:ttsError.length ? [NSString stringWithFormat:@"%@，已保留原声", ttsError] : @"合成失败，已保留原声"];
                return;
            }
            // 文件指纹保护：目标文件若已被改动（典型：路径被新录音复用），绝不安装，
            // 否则会 removeItem + copy 把别人/新录音的文件物理替换掉
            if (![weakSelf.inFlightStamp isEqualToString:[weakSelf fileStampForPath:path]]) {
                [weakSelf finishPipelineOk:NO path:path message:@"录音文件已被改动，保留原声"];
                return;
            }
            [weakSelf installSynthesizedAudio:audioPath ontoPath:path completion:^(BOOL installed) {
                if (weakSelf.finishedOnce || weakSelf.pipelineEpoch != epoch) return;
                if (installed) {
                    [weakSelf finishPipelineOk:YES path:path message:@"已转换为所选音色"];
                } else {
                    [weakSelf finishPipelineOk:NO path:path message:@"写入失败，已保留原声"];
                }
            }];
        }];
    }];
}

#pragma mark - 语音识别

- (NSString *)audioFormatForPath:(NSString *)path {
    NSString *ext = path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"m4a"] || [ext isEqualToString:@"aac"] ||
        [ext isEqualToString:@"mp3"] || [ext isEqualToString:@"wav"] ||
        [ext isEqualToString:@"ogg"] || [ext isEqualToString:@"mp4"]) {
        return ext;
    }
    if ([ext isEqualToString:@"caf"]) return @"aac";
    return @"m4a";
}

- (NSString *)textFromASRJSON:(NSDictionary *)json {
    id result = json[@"result"];
    if ([result isKindOfClass:[NSString class]]) return [(NSString *)result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([result isKindOfClass:[NSDictionary class]]) {
        NSString *text = result[@"text"];
        if (text.length) return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSArray *utterances = result[@"utterances"];
        if ([utterances isKindOfClass:[NSArray class]]) {
            NSMutableString *buf = [NSMutableString string];
            for (id u in utterances) {
                if (![u isKindOfClass:[NSDictionary class]]) continue;
                NSString *t = u[@"text"];
                if (t.length) [buf appendString:t];
            }
            if (buf.length) return [buf stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    }
    NSString *text = json[@"text"];
    if ([text isKindOfClass:[NSString class]] && text.length) {
        return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return nil;
}

- (void)recognizeAudioAtPath:(NSString *)path completion:(void(^)(NSString *text, NSString *error))completion {
    NSString *wavPath = [path stringByAppendingString:@".aweca.wav"];
    [AWECAUtils convertAudioAtPath:path toWAV16kPath:wavPath completion:^(BOOL success, NSError *error) {
        NSString *sendPath = success ? wavPath : path;
        [self uploadThenRecognizeAtPath:sendPath completion:^(NSString *text, NSString *err) {
            [[NSFileManager defaultManager] removeItemAtPath:wavPath error:nil];
            if (completion) completion(text, err);
        }];
    }];
}

#pragma mark - 标准版识别（TOS 上传 + submit + query 轮询）

// 上传录音到 TOS 拿公网 URL → submit → 轮询 query → 删除对象，文本原样回调给 TTS 合成
- (void)uploadThenRecognizeAtPath:(NSString *)path completion:(void(^)(NSString *text, NSString *error))completion {
    if (![AWECATOSUploader hasCredentials]) {
        if (completion) completion(nil, @"未配置 TOS：请先在「识别」设置里填写 AK/SK/Bucket/区域，已保留原声");
        return;
    }
    NSString *ext = path.pathExtension.lowercaseString;
    if (!ext.length) ext = @"wav";
    NSString *objectKey = [NSString stringWithFormat:@"aweca-asr/%@.%@", [[NSUUID UUID] UUIDString], ext];

    [AWECAUtils showToast:@"上传识别中..." duration:2.0];
    [AWECATOSUploader uploadFileAtPath:path objectKey:objectKey completion:^(NSString *url, NSError *error) {
        if (!url.length) {
            NSString *msg = error.localizedDescription ?: @"上传失败";
            if (completion) completion(nil, [NSString stringWithFormat:@"%@，已保留原声", msg]);
            return;
        }
        [self submitASRWithURL:url
                        format:([ext isEqualToString:@"wav"] ? @"wav" : [self audioFormatForPath:path])
                    completion:^(NSString *text, NSString *err) {
            [AWECATOSUploader deleteObject:objectKey completion:nil]; // 识别后清理，避免堆积
            if (completion) completion(text, err);
        }];
    }];
}

// submit：提交音频 URL，成功（X-Api-Status-Code=20000000）后进入 query 轮询
- (void)submitASRWithURL:(NSString *)url format:(NSString *)format
              completion:(void(^)(NSString *text, NSString *error))completion {
    AWECATTSManager *mgr = [AWECATTSManager shared];
    NSString *requestId = [[NSUUID UUID] UUIDString]; // submit 与 query 复用同一个 UUID
    NSMutableDictionary *audioDict = [@{
        @"url": url,
        @"format": format.length ? format : @"wav",
        @"language": @"zh-CN"
    } mutableCopy];
    if ([format isEqualToString:@"wav"]) {
        audioDict[@"codec"] = @"raw";
        audioDict[@"rate"] = @16000;
        audioDict[@"bits"] = @16;
        audioDict[@"channel"] = @1;
    }
    NSDictionary *body = @{
        @"user": @{ @"uid": mgr.appID.length ? mgr.appID : @"aweca_user" },
        @"audio": audioDict,
        @"request": @{
            @"model_name": @"bigmodel",
            @"enable_itn": @YES,
            @"enable_punc": @YES
        }
    };
    [self postASRSubmit:body requestId:requestId attempt:0 completion:^(NSString *error) {
        if (error) { if (completion) completion(nil, error); return; }
        [self pollASRQuery:requestId attempt:0 completion:completion];
    }];
}

- (void)postASRSubmit:(NSDictionary *)body requestId:(NSString *)requestId attempt:(NSInteger)attempt
            completion:(void(^)(NSString *error))completion {
    [self postASRRequest:body url:kASRSubmitURL requestId:requestId includeSequence:YES
               completion:^(NSDictionary *json, NSString *statusCode, NSString *error) {
        (void)json;
        if (!error && (!statusCode.length || [statusCode isEqualToString:@"20000000"] || [statusCode isEqualToString:@"0"])) {
            if (completion) completion(nil); // 提交成功（响应体为空）
            return;
        }
        // 网络类错误重试；接口返回的错误码不重试
        if (error && attempt + 1 < kASRSubmitRetries) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self postASRSubmit:body requestId:requestId attempt:attempt + 1 completion:completion];
            });
            return;
        }
        if (completion) {
            if (error) completion([error stringByAppendingString:@"，已保留原声"]);
            else {
                NSString *hint = AWECAASRCodeHint(statusCode) ?: @"提交失败";
                completion([NSString stringWithFormat:@"识别提交错误(%@): %@，已保留原声", statusCode ?: @"未知", hint]);
            }
        }
    }];
}

// query 轮询：20000001/20000002 继续等，20000000 取 result.text，其余按错误码映射中文
- (void)pollASRQuery:(NSString *)requestId attempt:(NSInteger)attempt
          completion:(void(^)(NSString *text, NSString *error))completion {
    if (attempt >= kASRMaxQueryRounds) {
        if (completion) completion(nil, @"识别超时（轮询用尽），已保留原声");
        return;
    }
    NSTimeInterval delay = (attempt == 0) ? 1.0 : kASRQueryInterval;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self postASRRequest:@{} url:kASRQueryURL requestId:requestId includeSequence:NO
                   completion:^(NSDictionary *json, NSString *statusCode, NSString *error) {
            if (error) {
                // 网络抖动记一轮，继续轮询（整体受 120s 看门狗兜底）
                [self pollASRQuery:requestId attempt:attempt + 1 completion:completion];
                return;
            }
            if ([statusCode isEqualToString:@"20000000"] || [statusCode isEqualToString:@"0"]) {
                NSString *text = [self textFromASRJSON:json];
                if (completion) completion(text.length ? text : nil, text.length ? nil : @"未识别到文字");
                return;
            }
            if ([statusCode isEqualToString:@"20000001"] || [statusCode isEqualToString:@"20000002"]) {
                [self pollASRQuery:requestId attempt:attempt + 1 completion:completion];
                return;
            }
            if ([statusCode isEqualToString:@"20000003"]) {
                if (completion) completion(nil, @"未检测到人声（静音），已保留原声");
                return;
            }
            NSString *msg = json[@"message"] ?: json[@"msg"] ?: AWECAASRCodeHint(statusCode) ?: @"失败";
            if (completion) {
                completion(nil, [NSString stringWithFormat:@"识别错误(%@): %@，已保留原声",
                                 statusCode ?: @"未知", msg]);
            }
        }];
    });
}

// 通用 POST：submit / query 共用；statusCode 取自 X-Api-Status-Code 响应头
- (void)postASRRequest:(NSDictionary *)body
                    url:(NSString *)url
             requestId:(NSString *)requestId
       includeSequence:(BOOL)includeSequence
             completion:(void(^)(NSDictionary *json, NSString *statusCode, NSString *error))completion {
    AWECATTSManager *mgr = [AWECATTSManager shared];
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!jsonData) jsonData = [NSData data];

    NSString *resourceId = AWECAASRTrim([[NSUserDefaults standardUserDefaults] stringForKey:kAWECAASRResourceId]);
    if (!resourceId.length) resourceId = kASRDefaultResourceId;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = jsonData;
    req.timeoutInterval = 30;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [mgr applyVolcanoHTTPAuthToRequest:req];
    [req setValue:resourceId forHTTPHeaderField:@"X-Api-Resource-Id"];
    [req setValue:requestId forHTTPHeaderField:@"X-Api-Request-Id"];
    if (includeSequence) [req setValue:@"-1" forHTTPHeaderField:@"X-Api-Sequence"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        void (^done)(NSDictionary *, NSString *, NSString *) = ^(NSDictionary *j, NSString *code, NSString *err) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(j, code, err); });
        };
        if (error) {
            done(nil, nil, [NSString stringWithFormat:@"识别网络错误: %@", error.localizedDescription]);
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSString *apiCode = AWECAASRHeader(http.allHeaderFields, @"X-Api-Status-Code");
        if (!apiCode.length) {
            done(nil, nil, @"识别响应异常（无状态码）");
            return;
        }
        NSDictionary *json = nil;
        if (data.length) {
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) json = obj;
        }
        done(json, apiCode, nil);
    }] resume];
}

#pragma mark - 覆盖本次录音

- (void)installSynthesizedAudio:(NSString *)synthPath ontoPath:(NSString *)targetPath completion:(void(^)(BOOL ok))completion {
    if (![[NSFileManager defaultManager] fileExistsAtPath:synthPath]) {
        if (completion) completion(NO);
        return;
    }
    NSString *ext = synthPath.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"m4a"] || [ext isEqualToString:@"aac"]) {
        NSError *err = nil;
        [[NSFileManager defaultManager] removeItemAtPath:targetPath error:nil];
        BOOL ok = [[NSFileManager defaultManager] copyItemAtPath:synthPath toPath:targetPath error:&err];
        if (completion) completion(ok);
        return;
    }

    NSString *tmp = [targetPath stringByAppendingString:@".aweca.m4a"];
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
    [AWECAUtils convertAudioAtPath:synthPath toOutputPath:tmp completion:^(BOOL success, NSError *error) {
        if (!success) {
            if (completion) completion(NO);
            return;
        }
        [[NSFileManager defaultManager] removeItemAtPath:targetPath error:nil];
        NSError *mvErr = nil;
        BOOL ok = [[NSFileManager defaultManager] moveItemAtPath:tmp toPath:targetPath error:&mvErr];
        if (!ok) {
            ok = [[NSFileManager defaultManager] copyItemAtPath:tmp toPath:targetPath error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        }
        if (completion) completion(ok);
    }];
}

@end
