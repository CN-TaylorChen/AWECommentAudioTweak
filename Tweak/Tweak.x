// 评论语音 Hook
// @cookieodd | github.com/cookieodd | t.me/cookieodd

#import "AWECAHeaders.h"
#import "AWECAUtils.h"
#import "AWECADownloadManager.h"
#import "AWECAAudioReplacer.h"
#import "AWECACommentHeaderButton.h"
#import "AWECARecordEnhance.h"
#import "AWECATTSManager.h"
#import "AWECAAudioPickerController.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

static void setupAudioIconElementHook(void);
static void setupAudioInputElementHook(void);

// 录音结束替换

%hook AWECommentAudioRecorderController

- (void)audioRecorderStartRecord:(id)recorder error:(id)error {
    %orig;
    if (!error) {
        [[AWECARecordEnhance shared] markCommentTakeStarted];
    }
}

- (void)clear {
    [[AWECARecordEnhance shared] markCommentTakeCancelled];
    %orig;
}

- (void)audioRecorderDidFinishRecording:(id)recorder success:(BOOL)success error:(id)error {
    NSString *path = self.audioFilePath.length ? self.audioFilePath : self.recorder.url.path;
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];

    // 取消残留：上滑取消时抖音也会以 success:YES 走到这里（文件落盘后被丢弃）。
    // cancelledTake 是状态位：从 clear（取消）起置位，到下一次录音开始（markCommentTakeStarted）才清零，
    // 因此无论取消的完成回调迟到多久都能识别；且取消的 DidFinishRecording 必先于用户下一次录音操作，
    // 不存在"误挡正常录音"的窗口（早期用 0.5s 时间窗，主线程忙时必漏）
    BOOL cancelResidue = enhance.cancelledTake;
    if (success && enhance.enhanceEnabled && enhance.armed && ![enhance shouldRunForCommentRecording]) {
        [AWECAUtils showToast:@"请先填写火山 API Key"];
        %orig;
        return;
    }

    if (success && !cancelResidue && [enhance shouldRunForCommentRecording] && path.length) {
        [enhance beginIfNeededAtPath:path];
        %orig;
        return;
    }

    if (success && [enhance shouldSkipStickyReplaceForPath:path]) {
        %orig;
        return;
    }

    if (success && [AWECAAudioReplacer shared].enabled) {
        NSString *recorderURL = self.recorder.url.path;
        %orig;
        NSString *pathAfter = self.audioFilePath;

        if (pathAfter.length > 0) {
            [[AWECAAudioReplacer shared] replaceAudioAtPath:pathAfter];
        } else if (recorderURL.length > 0) {
            [[AWECAAudioReplacer shared] replaceAudioAtPath:recorderURL];
        }
        [AWECAUtils showToast:@"语音已替换"];
    } else {
        %orig;
    }
}

- (void)setAudioFilePath:(NSString *)audioFilePath {
    %orig;
    if (!audioFilePath.length) return;
    if ([[AWECARecordEnhance shared] shouldSkipStickyReplaceForPath:audioFilePath]) return;
    if (![AWECAAudioReplacer shared].enabled) return;
    if ([[NSFileManager defaultManager] fileExistsAtPath:audioFilePath]) {
        [[AWECAAudioReplacer shared] replaceAudioAtPath:audioFilePath];
    }
}

%end

// 私聊（IM）录音转音色
//
// 血泪教训：钩子必须挂到「真正实现该方法的类」上，挂到持有者/调用者类上是死钩（编译通过、运行零反应）。
// 40.8.0 二进制 classlist 反查确认的实现分布：
//   recorderAnimationViewDidTapSendAudio:  -> AWEIMOptimizeAudioInputTouchView（新面板触摸层，UI 事件入口）
//   audioInputTouchView*                   -> AWEIMAudioRecordController / AWEIMFormatAudioRecordController
//   落盘发送：
//     AWEIMAudioRecordController       .sendRecordMessageIfNeededWithFilePath:audioRecorder:   (NSString 路径)
//     AWEIMFormatAudioRecordController .sendRecordMessageIfNeededWithData:audioRecorder:      (NSData，无落盘路径)
//   录音器：AWEIMAudioMessageRecorder.url
//
// 策略：每个流程只在「终局发送点」拦截一次（避免双击重复发），全程打 AWECA-IM 日志自证；
//       松手后有「发送 / 取消 / 转文字」确认面板，点发送才真正发消息，足够异步流水线跑完。

#pragma mark - 私聊工具函数

static NSString *AWECAPathFromValue(id v) {
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v length] ? (NSString *)v : nil;
    if ([v isKindOfClass:[NSURL class]]) return [(NSURL *)v path];
    return nil;
}

// 运行时安全取值：不依赖编译期类型，避免头文件/类名漂移导致编译失败
static id AWECASafeGet(id obj, NSString *name) {
    if (!obj || !name.length) return nil;
    SEL s = NSSelectorFromString(name);
    if (![obj respondsToSelector:s]) return nil;
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        return [obj performSelector:s];
#pragma clang diagnostic pop
    } @catch (NSException *e) {
        return nil;
    }
}

static NSString *AWECAPrivateTempPath(void) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"aweca_im"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"im_%.0f.m4a", [[NSDate date] timeIntervalSince1970] * 1000]];
}

// Format 架构直接传 NSData（无落盘路径）：先把原声落地成临时文件，再走同一条流水线
static NSString *AWECAPrivateMaterialize(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0) return nil;
    NSString *p = AWECAPrivateTempPath();
    return [data writeToFile:p atomically:YES] ? p : nil;
}

// 从入口自带值 / 控制器属性里找本次录音的真实文件路径（优先已存在的文件）
static NSString *AWECAPrivateResolvePath(id primary, id ctrl) {
    NSString *p = AWECAPathFromValue(primary);
    if (p.length && [[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    if (ctrl) {
        for (NSString *name in @[@"recordFilePath", @"audioFilePath", @"filePath", @"recordPath"]) {
            NSString *q = AWECAPathFromValue(AWECASafeGet(ctrl, name));
            if (q.length && [[NSFileManager defaultManager] fileExistsAtPath:q]) return q;
        }
    }
    return nil;
}

// 记录本次私聊录音的落盘路径（并按需兜底武装 + 尽早起跑流水线）
// v1.4.6：起跑前先复制快照——抖音私聊每条录音复用同一路径，流水线绝不在活文件上转换
static void AWECAPrivateNotePath(NSString *path) {
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    if (!path.length || !enhance.privateEnhanceEnabled) return;
    // 重放再入护栏：重放带的是插件自有快照路径，不是新录音，绝不能武装/覆盖 privateRecordPath
    if ([AWECARecordEnhance isPluginOwnedPath:path]) return;
    if (!enhance.privateArmed) [enhance markPrivateTakeStarted];
    enhance.privateRecordPath = path;
    [enhance privateBeginForSourcePath:path];   // 趁用户停确认面板上，提前消化数十秒合成耗时
}

static void AWECACall2(id target, SEL sel, id a, id b) {
    if (!target || !sel) return;
    ((void (*)(id, SEL, id, id))objc_msgSend)(target, sel, a, b);
}

// 发送闸门：返回 YES = 已接管（调用方不要再 %orig，由 fire 负责重放），NO = 直接放行。
// fire 在流水线结束后于主线程回调，调用方在其中执行真正的发送（可带上替换后的音频）。
static BOOL AWECAPrivateGate(const char *tag, NSString *path, void (^fire)(BOOL ok, NSString *message)) {
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    NSLog(@"AWECA-IM: [%s] send path=%@ armed=%d skip=%d",
          tag, path, enhance.privateArmed, enhance.privateSkipOnce);

    if (enhance.privateSkipOnce) {
        enhance.privateSkipOnce = NO;
        NSLog(@"AWECA-IM: [%s] passthrough (already enhanced)", tag);
        return NO;
    }
    if (path.length) enhance.privateRecordPath = path;
    if (![enhance shouldRunForPrivateRecording]) {
        NSLog(@"AWECA-IM: [%s] passthrough (not eligible)", tag);
        return NO;
    }

    NSString *p = [path copy];
    NSLog(@"AWECA-IM: [%s] INTERCEPT, enhancing %@", tag, p);
    [AWECAUtils showToast:@"识别合成中..." duration:2.0];
    // v1.4.6 快照隔离：流水线只对插件私有副本转换，抖音复用的活路径全程不被触碰；
    // 已取消（message 含"已取消"）绝不补发——取消过程中同步发消息会弄乱抖音录音 UI
    [enhance privateWaitForSourcePath:p completion:^(BOOL ok, NSString *message) {
        NSLog(@"AWECA-IM: [%s] pipeline done ok=%d msg=%@ aborted=%d",
              tag, ok, message, enhance.privateAborted);
        if (message.length) [AWECAUtils showToast:message duration:2.5];
        if (!ok && [message containsString:@"已取消"]) {
            [enhance resetPrivateTake];
            return;
        }
        if (enhance.privateAborted) {
            [enhance resetPrivateTake];
            return;
        }
        enhance.privateSkipOnce = YES;
        void (^safeFire)(void) = ^{
            @try {
                if (fire) fire(ok, message);
            } @catch (NSException *e) {
                NSLog(@"AWECA-IM: [%s] fire exception: %@", tag, e);
            }
            [enhance resetPrivateTake];
        };
        if ([NSThread isMainThread]) safeFire();
        else dispatch_async(dispatch_get_main_queue(), safeFire);
    }];
    return YES;
}

#pragma mark - 私聊声临状态条（v1.4.6）

// ===== 新面板触摸层：UI 事件入口（40.8.0 私聊实际走这条）=====
// 注意：头文件里该类只是 NSObject 前向声明，UIView 属性一律经 id 桥接访问；
// 新增方法必须 %new，钩子内经 objc_msgSend 调用（编译器看不到选择器声明）

%hook AWEIMOptimizeAudioInputTouchView

// 手势开始：武装私聊场景（兜底，控制器 delegate 的 TouchDown 也会武装）
- (void)startRecord {
    %orig;
    NSLog(@"AWECA-IM: touchView startRecord");
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    if (enhance.privateEnhanceEnabled) [enhance markPrivateTakeStarted];
}

- (void)cancelRecord {
    // 铁律：%orig 必须最先执行——原生取消录音绝不能被插件状态代码挡住
    // （状态代码若抛异常，%orig 不执行，触摸层卡在"正在录音"，必须重进会话才能恢复）
    %orig;
    NSLog(@"AWECA-IM: touchView cancelRecord");
    @try {
        [[AWECARecordEnhance shared] markPrivateTakeCancelled];
    } @catch (NSException *e) {
        NSLog(@"AWECA-IM: cancelRecord state exception: %@", e);
    }
}

- (void)stopRecordWithInTranslate:(BOOL)inTranslate {
    %orig;
    NSLog(@"AWECA-IM: touchView stopRecord inTranslate=%d", inTranslate);
    if (inTranslate) [[AWECARecordEnhance shared] markPrivateTakeCancelled];
}

// 取消：撤装，防止误拦截后续的发送
- (void)recorderAnimationViewDidTapCancel:(id)view {
    %orig;
    NSLog(@"AWECA-IM: touchView DidTapCancel");
    @try {
        [[AWECARecordEnhance shared] markPrivateTakeCancelled];
    } @catch (NSException *e) {
        NSLog(@"AWECA-IM: DidTapCancel state exception: %@", e);
    }
}

// 点「发送语音」：本层只放行，真正的拦截放在控制器终局发送点（避免双击重复发）
- (void)recorderAnimationViewDidTapSendAudio:(id)view {
    NSLog(@"AWECA-IM: touchView DidTapSendAudio (passthrough)");
    %orig;
}

%end

// ===== 老控制器（文件路径架构）=====
%hook AWEIMAudioRecordController

// 录音结束：记下路径并尽早起跑流水线
- (void)audioRecorderDidFinishRecording:(id)recorder success:(BOOL)success action:(NSInteger)action error:(id)error {
    %orig;
    NSString *path = self.recordFilePath;
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    NSLog(@"AWECA-IM: CtrlDidFinish(action) success=%d action=%ld path=%@ armed=%d",
          success, (long)action, path, enhance.privateArmed);
    if (!success) return;
    if (!path.length) path = AWECAPathFromValue(AWECASafeGet(recorder, @"url"));
    AWECAPrivateNotePath(path);
}

// 手指按下：武装
- (void)audioInputTouchViewTouchDownInside:(id)view {
    %orig;
    NSLog(@"AWECA-IM: CtrlTouchDown");
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    if (enhance.privateEnhanceEnabled) [enhance markPrivateTakeStarted];
}

// 抬起（取消 / 转文字）→ 撤装
- (void)audioInputTouchViewTouchUpInside:(id)view cancelled:(BOOL)cancelled isInTranslate:(BOOL)isInTranslate {
    %orig;
    NSLog(@"AWECA-IM: CtrlTouchUp cancelled=%d isInTranslate=%d", cancelled, isInTranslate);
    if (cancelled || isInTranslate) [[AWECARecordEnhance shared] markPrivateTakeCancelled];
}

- (void)audioInputTouchViewTouchUpOutside:(id)view cancelled:(BOOL)cancelled {
    %orig;
    NSLog(@"AWECA-IM: CtrlTouchUpOutside cancelled=%d", cancelled);
    if (cancelled) [[AWECARecordEnhance shared] markPrivateTakeCancelled];
}

- (void)audioInputTouchViewDidTapCancel:(id)view {
    %orig;
    NSLog(@"AWECA-IM: CtrlDidTapCancel");
    @try {
        [[AWECARecordEnhance shared] markPrivateTakeCancelled];
    } @catch (NSException *e) {
        NSLog(@"AWECA-IM: CtrlDidTapCancel state exception: %@", e);
    }
}

// 点「发送语音」（面板确认）：放行，由终局发送点统一拦截
- (void)audioInputTouchViewDidTapSendAudio:(id)view {
    NSLog(@"AWECA-IM: CtrlDidTapSendAudio (passthrough)");
    %orig;
}

// 终局发送点（松手即发 / 面板确认都会走到这里）：拦截 → 跑流水线 → 重放
- (void)sendRecordMessageIfNeededWithFilePath:(id)filePath audioRecorder:(id)recorder {
    __weak id wctrl = self;   // 流水线数十秒，期间用户可能退出会话：弱引用防重放消息到已析构对象
    NSString *path = AWECAPrivateResolvePath(filePath, self);
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    NSLog(@"AWECA-IM: CtrlSend(file) raw=%@ path=%@ armed=%d", filePath, path, enhance.privateArmed);
    @try { AWECAPrivateNotePath(path); } @catch (NSException *e) {}
    if (AWECAPrivateGate("ctrl-file", path, ^(BOOL ok, NSString *m) {
        // v1.4.6 快照重放：发的始终是副本路径（成功=合成音频，失败=原声副本）。
        // 旧做法成功时发原路径——若期间用户已录下一条（抖音复用同一路径），
        // 发出去的会是下一条的声音；失败时发原路径也可能拿到被改动的内容
        NSString *snap = [enhance snapshotPathForSourcePath:path];
        NSString *replayPath = (snap.length && [[NSFileManager defaultManager] fileExistsAtPath:snap]) ? snap : path;
        void (^go)(void) = ^{
            __strong id sctrl = wctrl;
            if (!sctrl) { NSLog(@"AWECA-IM: ctrl-file replay skipped (controller gone)"); return; }
            AWECACall2(sctrl, @selector(sendRecordMessageIfNeededWithFilePath:audioRecorder:), replayPath, recorder);
        };
        if ([NSThread isMainThread]) go();
        else dispatch_async(dispatch_get_main_queue(), go);
    })) return;
    %orig;
}

%end

// ===== 新控制器（Format / NSData 架构）=====
%hook AWEIMFormatAudioRecordController

- (void)audioRecorderDidFinishRecording:(id)recorder success:(BOOL)success action:(NSInteger)action error:(id)error {
    %orig;
    NSString *path = AWECAPathFromValue(AWECASafeGet(recorder, @"url"));
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    NSLog(@"AWECA-IM: FormatDidFinish success=%d path=%@ armed=%d", success, path, enhance.privateArmed);
    if (!success) return;
    AWECAPrivateNotePath(path);
}

- (void)audioInputTouchViewTouchDownInside:(id)view {
    %orig;
    NSLog(@"AWECA-IM: FormatTouchDown");
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    if (enhance.privateEnhanceEnabled) [enhance markPrivateTakeStarted];
}

- (void)audioInputTouchViewTouchUpInside:(id)view cancelled:(BOOL)cancelled isInTranslate:(BOOL)isInTranslate {
    %orig;
    NSLog(@"AWECA-IM: FormatTouchUp cancelled=%d isInTranslate=%d", cancelled, isInTranslate);
    if (cancelled || isInTranslate) [[AWECARecordEnhance shared] markPrivateTakeCancelled];
}

- (void)audioInputTouchViewTouchUpOutside:(id)view cancelled:(BOOL)cancelled {
    %orig;
    NSLog(@"AWECA-IM: FormatTouchUpOutside cancelled=%d", cancelled);
    if (cancelled) [[AWECARecordEnhance shared] markPrivateTakeCancelled];
}

- (void)audioInputTouchViewDidTapCancel:(id)view {
    %orig;
    NSLog(@"AWECA-IM: FormatDidTapCancel");
    @try {
        [[AWECARecordEnhance shared] markPrivateTakeCancelled];
    } @catch (NSException *e) {
        NSLog(@"AWECA-IM: FormatDidTapCancel state exception: %@", e);
    }
}

- (void)audioInputTouchViewDidTapSendAudio:(id)view {
    NSLog(@"AWECA-IM: FormatDidTapSendAudio (passthrough)");
    %orig;
}

// 终局发送点：直接传 NSData（无落盘路径）→ 落地临时文件再走同一条流水线，
// 流水线结束后读回文件内容，重新发送（失败则发原声）
- (void)sendRecordMessageIfNeededWithData:(id)data audioRecorder:(id)recorder {
    __weak id wctrl = self;   // 流水线数十秒，期间用户可能退出会话：弱引用防重放消息到已析构对象
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    NSString *path = AWECAPrivateMaterialize(data);
    NSLog(@"AWECA-IM: FormatSend(data) len=%lu path=%@ armed=%d",
          (unsigned long)([data isKindOfClass:[NSData class]] ? ((NSData *)data).length : 0),
          path, enhance.privateArmed);
    @try { AWECAPrivateNotePath(path); } @catch (NSException *e) {}
    if (AWECAPrivateGate("format-data", path, ^(BOOL ok, NSString *m) {
        NSData *outData = ok ? [NSData dataWithContentsOfFile:path] : nil;
        NSData *final = (outData.length ? outData
                         : ([data isKindOfClass:[NSData class]] ? (NSData *)data : nil));
        void (^go)(void) = ^{
            __strong id sctrl = wctrl;
            if (!sctrl) { NSLog(@"AWECA-IM: format-data replay skipped (controller gone)"); return; }
            AWECACall2(sctrl, @selector(sendRecordMessageIfNeededWithData:audioRecorder:), final, recorder);
        };
        if ([NSThread isMainThread]) go();
        else dispatch_async(dispatch_get_main_queue(), go);
    })) return;
    %orig;
}

%end

// ===== 录音器层：兜底记录落盘路径 + 武装 =====
%hook AWEIMAudioMessageRecorder

- (void)audioRecorderDidFinishRecording:(id)recorder successfully:(BOOL)success action:(NSInteger)action {
    %orig;
    NSString *path = self.url.path;
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    NSLog(@"AWECA-IM: RecorderFinish success=%d path=%@ armed=%d", success, path, enhance.privateArmed);
    if (!success || !path.length) return;
    AWECAPrivateNotePath(path);
}

%end

// 播放时缓存地址

%hook AWECommentAudioPlayerManager

- (void)playAudioWithVideoModel:(id)videoModel startTime:(double)startTime audioEffectExternInfo:(id)info {
    if (videoModel && [videoModel isKindOfClass:[NSString class]]) {
        NSString *jsonStr = (NSString *)videoModel;
        [[AWECADownloadManager shared] parseAndCacheVideoModelJSON:jsonStr];
    }
    %orig;
}

- (void)playAudioWithVideoModel:(id)videoModel startTime:(double)startTime {
    if (videoModel && [videoModel isKindOfClass:[NSString class]]) {
        [[AWECADownloadManager shared] parseAndCacheVideoModelJSON:(NSString *)videoModel];
    }
    %orig;
}

%end

// 长按保存语音

%hook AWECommentLongPressPanelAdaptar

- (void)showLongPressPanelWithParam:(id)param config:(id)config showSheetCompletion:(id)showCompletion dismissSheetCompletion:(id)dismissCompletion {
    %orig;

    AWECommentModel *comment = nil;
    if ([param respondsToSelector:@selector(selectdComment)]) {
        comment = [(AWECommentLongPressPanelParam *)param selectdComment];
    }

    if (!comment || !comment.audioModel) {
        return;
    }

    AWECommentModel *savedComment = comment;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[AWECADownloadManager shared] showSaveDialogAndDownload:savedComment];
    });
}

%end

// 上传前再次替换

%hook AWECommentAudioUploadManager

- (void)startUploadAudioWithFilePath:(id)filePath {
    NSString *path = (NSString *)filePath;
    if (![[AWECARecordEnhance shared] shouldSkipStickyReplaceForPath:path] &&
        [AWECAAudioReplacer shared].enabled && filePath) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[AWECAAudioReplacer shared] replaceAudioAtPath:path];
        }
    }
    %orig;
}

- (void)uploadAudioWithFilePath:(id)filePath completion:(id)completion {
    NSString *path = (NSString *)filePath;
    if (![[AWECARecordEnhance shared] shouldSkipStickyReplaceForPath:path] &&
        [AWECAAudioReplacer shared].enabled && filePath) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[AWECAAudioReplacer shared] replaceAudioAtPath:path];
        }
    }
    %orig;
}

- (void)uploadAudioWithFilePath:(id)filePath authCompletion:(id)authCompletion completion:(id)completion {
    NSString *path = (NSString *)filePath;
    if (![[AWECARecordEnhance shared] shouldSkipStickyReplaceForPath:path] &&
        [AWECAAudioReplacer shared].enabled && filePath) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[AWECAAudioReplacer shared] replaceAudioAtPath:path];
        }
    }
    %orig;
}

%end


// 预览气泡替换

static void (*orig_generateAudioPreviewBubble)(id self, SEL _cmd, id recordedModel);
static void hook_generateAudioPreviewBubble(id self, SEL _cmd, id recordedModel) {
    NSString *audioPath = [recordedModel valueForKey:@"audioFilePath"];
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];

    if (recordedModel && [enhance shouldRunForCommentRecording] && audioPath.length) {
        [enhance waitForEnhancedPath:audioPath completion:^(BOOL ok, NSString *message) {
            if (ok) {
                double realDur = [AWECAUtils audioDurationAtPath:audioPath];
                [recordedModel setValue:@((long long)(realDur * 1000)) forKey:@"duration"];
            }
            orig_generateAudioPreviewBubble(self, _cmd, recordedModel);
            if (message.length) [AWECAUtils showToast:message duration:2.5];
        }];
        return;
    }

    if (recordedModel && ![enhance shouldSkipStickyReplaceForPath:audioPath] && [AWECAAudioReplacer shared].enabled) {
        if (audioPath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:audioPath]) {
            BOOL ok = [[AWECAAudioReplacer shared] replaceAudioAtPath:audioPath];

            if (ok) {
                double realDur = [AWECAUtils audioDurationAtPath:audioPath];
                long long realMs = (long long)(realDur * 1000);
                [recordedModel setValue:@(realMs) forKey:@"duration"];
            }
        }
    }
    orig_generateAudioPreviewBubble(self, _cmd, recordedModel);
}

static void setupAudioInputElementHook(void) {
    Class cls = NSClassFromString(@"AWECommentInputViewSwiftImpl.CommentInputAudioInputElement");
    if (!cls) {
        return;
    }
    SEL sel = @selector(generateAudioPreviewBubbleWithRecordedModel:);
    Method method = class_getInstanceMethod(cls, sel);
    if (method) {
        orig_generateAudioPreviewBubble = (void (*)(id, SEL, id))method_getImplementation(method);
        method_setImplementation(method, (IMP)hook_generateAudioPreviewBubble);
    }
}

// 麦克风原生录音

static void (*orig_audioIconViewDidLoad)(id self, SEL _cmd);
static void hook_audioIconViewDidLoad(id self, SEL _cmd) {
    orig_audioIconViewDidLoad(self, _cmd);

    UIView *elementView = nil;
    if ([self respondsToSelector:@selector(view)]) {
        elementView = [self performSelector:@selector(view)];
    }
    if (!elementView) return;

    UIView *redDot = [[UIView alloc] initWithFrame:CGRectMake(elementView.bounds.size.width - 8, 2, 6, 6)];
    redDot.backgroundColor = [UIColor redColor];
    redDot.layer.cornerRadius = 3;
    redDot.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    redDot.hidden = ![AWECARecordEnhance shouldShowStatusDot];
    redDot.tag = kAWECAStatusDotTag;
    [elementView addSubview:redDot];
}

static void (*orig_handleAudioButton)(id self, SEL _cmd);
static void hook_handleAudioButton(id self, SEL _cmd) {
    [[AWECARecordEnhance shared] armFromCommentButton];
    orig_handleAudioButton(self, _cmd);
}

static void setupAudioIconElementHook(void) {
    Class cls = NSClassFromString(@"AWECommentInputViewSwiftImpl.CommentAudioIconElement");
    if (!cls) return;
    SEL sel = @selector(viewDidLoad);
    Method method = class_getInstanceMethod(cls, sel);
    if (method) {
        orig_audioIconViewDidLoad = (void (*)(id, SEL))method_getImplementation(method);
        method_setImplementation(method, (IMP)hook_audioIconViewDidLoad);
    }

    SEL btnSel = @selector(handleAudioButton);
    Method btnMethod = class_getInstanceMethod(cls, btnSel);
    if (btnMethod) {
        orig_handleAudioButton = (void (*)(id, SEL))method_getImplementation(btnMethod);
        method_setImplementation(btnMethod, (IMP)hook_handleAudioButton);
    }
}

// 插件初始化

%ctor {
    @autoreleasepool {
        [AWECAUtils ensureDirectoriesExist];

        [AWECAAudioReplacer shared];
        [AWECARecordEnhance shared];

        setupAudioInputElementHook();
        setupAudioIconElementHook();
        AWECASetupCommentHeaderButton();
    }
}
