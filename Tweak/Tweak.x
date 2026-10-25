// 评论语音 Hook
// @cookieodd | github.com/cookieodd | t.me/cookieodd

#import "AWECAHeaders.h"
#import "AWECAUtils.h"
#import "AWECADownloadManager.h"
#import "AWECAAudioReplacer.h"
#import "AWECACommentHeaderButton.h"
#import "AWECARecordEnhance.h"
#import <objc/runtime.h>
#import <objc/message.h>

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
// 40.8.0 实测：私聊录音 UI 走新 delegate 家族 recorderAnimationView*（AWEIMRichRecorderAnimationViewDelegate），
// 老的 audioInputTouchView* 是另一套面板。两套都 hook，谁被调用谁生效。
// 关键点：私信语音松手后有「发送/取消/转文字」确认面板，点发送才真正发消息，
// 这给了异步流水线（上传→ASR→TTS→替换，数十秒）足够的时间窗，策略为「拦截发送 → 跑流水线 → 放行」。

// 拦截发送：返回 YES 表示已接管（调用方不要再 %orig），NO 表示直接放行
static BOOL AWECAPrivateInterceptSend(id target, SEL sel, id arg, const char *tag) {
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    NSLog(@"AWECA-IM: [%s] send called path=%@ armed=%d skip=%d", tag, enhance.privateRecordPath, enhance.privateArmed, enhance.privateSkipOnce);
    if (enhance.privateSkipOnce) {
        enhance.privateSkipOnce = NO;
        NSLog(@"AWECA-IM: [%s] passthrough (already enhanced)", tag);
        return NO;
    }
    if (![enhance shouldRunForPrivateRecording]) return NO;

    NSString *path = [enhance.privateRecordPath copy];
    NSLog(@"AWECA-IM: [%s] INTERCEPT, enhancing %@", tag, path);
    [AWECAUtils showToast:@"识别合成中..." duration:2.0];
    [enhance runPrivateEnhanceAtPath:path completion:^(BOOL ok, NSString *message) {
        NSLog(@"AWECA-IM: [%s] pipeline done ok=%d msg=%@", tag, ok, message);
        if (message.length) [AWECAUtils showToast:message duration:2.5];
        enhance.privateSkipOnce = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [target performSelector:sel withObject:arg];
#pragma clang diagnostic pop
        [enhance resetPrivateTake];
    }];
    return YES;
}

%hook AWEIMAudioRecordController

// 新版签名（带 action 参数，IPA 40.8.0 方法名池确认存在）
- (void)audioRecorderDidFinishRecording:(id)recorder success:(BOOL)success action:(NSInteger)action error:(id)error {
    %orig;
    NSString *path = self.recordFilePath;
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    NSLog(@"AWECA-IM: CtrlDidFinish(action) success=%d path=%@", success, path);
    if (success && path.length) enhance.privateRecordPath = path;
}

// 旧版签名（与评论区同款，两个变体都 hook，真机确认哪个被触发后清理）
- (void)audioRecorderDidFinishRecording:(id)recorder success:(BOOL)success error:(id)error {
    %orig;
    NSString *path = self.recordFilePath;
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    NSLog(@"AWECA-IM: CtrlDidFinish(simple) success=%d path=%@", success, path);
    if (success && path.length) enhance.privateRecordPath = path;
}

%end

// 录音器层：新旧架构共用（控制器无论哪个类，_recorder 都是 IESIMAudioMessageRecorderInterface），
// 录音落盘路径以这里为准，是最可靠的路径来源
%hook AWEIMAudioMessageRecorder

- (void)audioEngineRecorder:(id)engine didFinishRecordingWithData:(id)data successfully:(BOOL)success {
    %orig;
    NSString *path = self.url.path;
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    NSLog(@"AWECA-IM: RecorderFinish success=%d path=%@ armed=%d", success, path, enhance.privateArmed);
    if (!success || !path.length) return;
    // 兜底武装：若触摸按下事件未被 hook 到（新面板走别的入口），这里补齐
    if (!enhance.privateArmed) [enhance markPrivateTakeStarted];
    enhance.privateRecordPath = path;
}

%end

%hook AWEIMDNewInputViewController

// 手指按下：进入录音，武装私聊场景
- (void)audioInputTouchViewTouchDownInside:(id)view {
    %orig;
    NSLog(@"AWECA-IM: TouchDown");
    [[AWECARecordEnhance shared] markPrivateTakeStarted];
}

// 抬起（含 isInTranslate 变体）：取消 或 转文字模式都撤装
- (void)audioInputTouchViewTouchUpInside:(id)view cancelled:(BOOL)cancelled isInTranslate:(BOOL)isInTranslate {
    %orig;
    NSLog(@"AWECA-IM: TouchUp(full) cancelled=%d isInTranslate=%d", cancelled, isInTranslate);
    if (cancelled || isInTranslate) [[AWECARecordEnhance shared] markPrivateTakeCancelled];
}

// 抬起（简单变体）
- (void)audioInputTouchViewTouchUpInside:(id)view cancelled:(BOOL)cancelled {
    %orig;
    NSLog(@"AWECA-IM: TouchUp(simple) cancelled=%d", cancelled);
    if (cancelled) [[AWECARecordEnhance shared] markPrivateTakeCancelled];
}

// 抬起时手指在区域外（取消）
- (void)audioInputTouchViewTouchUpOutside:(id)view cancelled:(BOOL)cancelled {
    %orig;
    NSLog(@"AWECA-IM: TouchUpOutside cancelled=%d", cancelled);
    if (cancelled) [[AWECARecordEnhance shared] markPrivateTakeCancelled];
}

// ===== 发送时机（真正的拦截点）=====

// 新录音面板：点「发送语音」——40.8.0 私聊实际走这条
- (void)recorderAnimationViewDidTapSendAudio:(id)view {
    if (AWECAPrivateInterceptSend(self, @selector(recorderAnimationViewDidTapSendAudio:), view, "new-panel")) return;
    %orig;
}

// 老录音面板：点「发送语音」
- (void)audioInputTouchViewDidTapSendAudio:(id)view {
    if (AWECAPrivateInterceptSend(self, @selector(audioInputTouchViewDidTapSendAudio:), view, "old-panel")) return;
    %orig;
}

// 取消 / 转文字：撤装，防止误拦截后续的发送
- (void)recorderAnimationViewDidTapCancel:(id)view {
    %orig;
    NSLog(@"AWECA-IM: panel DidTapCancel");
    [[AWECARecordEnhance shared] markPrivateTakeCancelled];
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
