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
@property (nonatomic, assign) NSTimeInterval lastCancelAt; // 最近一次取消的时间戳（reference 时间），供钩子识别取消残留
@end

@implementation AWECARecordEnhance

+ (instancetype)shared {
    static AWECARecordEnhance *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[AWECARecordEnhance alloc] init];
        inst.waiters = [NSMutableArray array];
        inst->_enhanceEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:kAWECAEnhanceEnabled];
    });
    return inst;
}

+ (BOOL)shouldShowStatusDot {
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    return [AWECAAudioReplacer shared].enabled || enhance.enhanceEnabled;
}

- (void)setEnhanceEnabled:(BOOL)enhanceEnabled {
    if (_enhanceEnabled == enhanceEnabled) return;
    _enhanceEnabled = enhanceEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:enhanceEnabled forKey:kAWECAEnhanceEnabled];
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
    self.lastCancelAt = 0; // 新录音开始，此前的取消不再相关
}

- (void)markCommentTakeCancelled {
    self.lastCancelAt = [NSDate timeIntervalSinceReferenceDate];
    // 取消时必须作废在飞流水线：否则取消的录音会白跑上传+识别+合成，
    // 其结果（成功/失败）还会写入路径缓存，导致抖音复用同一路径时后续录音全部假提示
    [self invalidatePipeline:@"已取消，保留原声"];
}

// 作废当前流水线：epoch++ 使所有迟到回调被防护挡下（不 install、不写缓存、不假 toast）
- (void)invalidatePipeline:(NSString *)message {
    if (!self.busy) {
        self.armed = NO;
        return;
    }
    self.pipelineEpoch += 1;
    self.finishedOnce = YES;
    self.busy = NO;
    self.inFlightPath = nil;
    self.inFlightStamp = nil;
    self.lastMessage = message;
    [self flushWaitersOk:NO path:nil message:message];
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

- (void)waitForEnhancedPath:(NSString *)path
                 completion:(void(^)(BOOL ok, NSString *message))completion {
    if (!path.length) {
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

// 只唤醒路径匹配的等待者；不匹配的（旧流水线结束时挂进来的新路径）以冲突失败唤醒，
// 避免旧结果张冠李戴（toast 假成功、时长按错文件算、新录音实际未增强）
- (void)flushWaitersOk:(BOOL)ok path:(NSString *)path message:(NSString *)msg {
    NSArray *list = [self.waiters copy];
    [self.waiters removeAllObjects];
    for (NSDictionary *entry in list) {
        void (^cb)(BOOL, NSString *) = entry[@"block"];
        NSString *wPath = entry[@"path"];
        BOOL match = (path.length > 0 && [wPath isEqualToString:path]);
        cb(match ? ok : NO, match ? msg : @"与上一个任务冲突，请重试");
    }
}

- (void)finishPipelineOk:(BOOL)ok path:(NSString *)path message:(NSString *)msg {
    if (self.finishedOnce) return;
    self.finishedOnce = YES;
    self.pipelineEpoch += 1;
    self.busy = NO;
    self.inFlightPath = nil;
    self.inFlightStamp = nil;
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
