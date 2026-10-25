// 豆包 TTS 管理器
// @cookieodd | github.com/cookieodd | t.me/cookieodd

#import "AWECATTSManager.h"
#import "AWECAUtils.h"
#import "AWECAAudioReplacer.h"
#import <UIKit/UIKit.h>
#import <math.h>
#import <string.h>

#define kDefaultVoiceType   @"zh_female_cancan_uranus_bigtts"

#define kTTSV3UnidirURL @"https://openspeech.bytedance.com/api/v3/tts/unidirectional"
#define kTTSResourceTTS2 @"seed-tts-2.0"
#define kTTSResourceICL2 @"seed-icl-2.0"

#define kFishTTSURL     @"https://api.fish.audio/v1/tts"

static NSString *AWECATrim(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return @"";
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *AWECAHeader(NSDictionary *headers, NSString *key) {
    if (![headers isKindOfClass:[NSDictionary class]] || !key.length) return nil;
    id v = headers[key];
    if ([v isKindOfClass:[NSString class]]) return v;
    for (NSString *k in headers) {
        if ([k caseInsensitiveCompare:key] == NSOrderedSame) {
            id x = headers[k];
            return [x isKindOfClass:[NSString class]] ? x : nil;
        }
    }
    return nil;
}

static NSArray<NSDictionary *> *AWECAJSONObjectsFromData(NSData *data) {
    NSMutableArray *out = [NSMutableArray array];
    if (!data.length) return out;
    const uint8_t *bytes = data.bytes;
    NSUInteger len = data.length;
    NSUInteger i = 0;
    while (i < len) {
        while (i < len && bytes[i] <= 32) i++;
        if (i >= len) break;
        if (i + 5 <= len && memcmp(bytes + i, "data:", 5) == 0) {
            i += 5;
            while (i < len && bytes[i] == ' ') i++;
        } else if (i + 6 <= len && memcmp(bytes + i, "event:", 6) == 0) {
            while (i < len && bytes[i] != '\n') i++;
            continue;
        }
        if (i >= len || bytes[i] != '{') { i++; continue; }
        NSUInteger start = i;
        int depth = 0;
        BOOL inStr = NO, esc = NO;
        BOOL closed = NO;
        for (; i < len; i++) {
            char c = (char)bytes[i];
            if (inStr) {
                if (esc) esc = NO;
                else if (c == '\\') esc = YES;
                else if (c == '"') inStr = NO;
                continue;
            }
            if (c == '"') inStr = YES;
            else if (c == '{') depth++;
            else if (c == '}') {
                depth--;
                if (depth == 0) {
                    NSData *one = [data subdataWithRange:NSMakeRange(start, i - start + 1)];
                    id obj = [NSJSONSerialization JSONObjectWithData:one options:0 error:nil];
                    if ([obj isKindOfClass:[NSDictionary class]]) [out addObject:obj];
                    i++;
                    closed = YES;
                    break;
                }
            }
        }
        if (!closed) break;
    }
    return out;
}

@interface AWECATTSManager ()
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, copy, readwrite) NSString *lastSynthesizedPath;
@end

@implementation AWECATTSManager

+ (instancetype)shared {
    static AWECATTSManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AWECATTSManager alloc] init];
        [instance loadConfig];
    });
    return instance;
}

#pragma mark - 合成

- (void)synthesizeText:(NSString *)text
            completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion {
    [self synthesizeText:text previewOnly:NO completion:completion];
}

- (void)previewText:(NSString *)text
         completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion {
    [self synthesizeText:text previewOnly:YES completion:completion];
}

- (void)synthesizeText:(NSString *)text
           previewOnly:(BOOL)previewOnly
            completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion {
    if (!text || text.length == 0) {
        if (completion) completion(NO, nil, @"请输入要合成的文字");
        return;
    }

    if (self.fishEngine) {
        [self synthesizeFishText:text previewOnly:previewOnly completion:completion];
        return;
    }
    [self synthesizeVolcanoV3Text:text previewOnly:previewOnly completion:completion];
}

- (void)synthesizeVolcanoPreviewText:(NSString *)text
                          completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion {
    // 流水线统一入口：按引擎分流（录音转音色 ASR 仍走火山，仅 TTS 分流）
    if (self.fishEngine) {
        [self synthesizeFishText:text previewOnly:NO completion:completion];
        return;
    }
    [self synthesizeVolcanoV3Text:text previewOnly:YES completion:completion];
}

static int aweca_mapRatioToV3(float ratio, int scale, int lo, int hi) {
    if (ratio < 0.01f) ratio = 1.0f;
    int v = (int)lround((ratio - 1.0f) * (double)scale);
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    return v;
}

static int aweca_mapPitchToV3(float ratio) {
    int v = (int)lround((ratio - 1.0f) * 12.0);
    if (v < -12) v = -12;
    if (v > 12) v = 12;
    return v;
}

+ (NSString *)canonicalDialect:(NSString *)raw {
    NSString *s = AWECATrim(raw);
    if (!s.length) return @"";
    NSString *l = s.lowercaseString;
    if ([s isEqualToString:@"东北"] || [l isEqualToString:@"dongbei"]) return @"dongbei";
    if ([s isEqualToString:@"陕西"] || [l isEqualToString:@"shaanxi"]) return @"shaanxi";
    if ([s isEqualToString:@"四川"] || [l isEqualToString:@"sichuan"]) return @"sichuan";
    return @"";
}

- (BOOL)currentVoiceSupportsDialect {
    return [[self volcanoTTS2Speaker] isEqualToString:kAWECATTSDialectSpeaker];
}

- (NSString *)volcanoSpeakerId {
    if (self.voiceType.length > 0) return self.voiceType;
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kAWECATTSVolcanoVoiceType];
    if (saved.length > 0) return saved;
    return kDefaultVoiceType;
}

- (NSString *)volcanoTTS2Speaker {
    NSString *s = [self volcanoSpeakerId] ?: @"";
    NSString *l = [s lowercaseString];
    if ([l containsString:@"uranus"]) return s;

    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"saturn_zh_female_cancan_tob": @"zh_female_cancan_uranus_bigtts",
            @"BV700_V2_streaming": @"zh_female_cancan_uranus_bigtts",
            @"zh_female_cancan_mars_bigtts": @"zh_female_cancan_uranus_bigtts",
            @"BV001_V2_streaming": @"zh_female_vv_uranus_bigtts",
            @"BV002_V2_streaming": @"zh_male_m191_uranus_bigtts",
            @"BV113_streaming": @"zh_male_taocheng_uranus_bigtts",
            @"BV102_streaming": @"zh_female_xiaohe_uranus_bigtts",
            @"BV406_V2_streaming": @"zh_male_m191_uranus_bigtts",
            @"BV405_streaming": @"zh_female_qingchezizi_uranus_bigtts",
            @"zh_female_xueayi_saturn_bigtts": @"zh_female_xiaoxue_uranus_bigtts",
            @"zh_female_santongyongns_saturn_bigtts": @"zh_female_liuchangnv_uranus_bigtts",
        };
    });
    NSString *mapped = map[s];
    if (mapped.length) return mapped;
    if ([s hasPrefix:@"saturn_"]) {
        return [@"ICL_uranus_" stringByAppendingString:[s substringFromIndex:7]];
    }
    if ([l containsString:@"saturn"]) {
        return [s stringByReplacingOccurrencesOfString:@"saturn" withString:@"uranus"];
    }
    // 未知音色 ID 原样透传，支持自定义音色（复刻 S_xxx、商店音色等）
    return s;
}

- (NSString *)volcanoTTSAdditionsJSONAllowContext:(BOOL)allowContext {
    NSMutableDictionary *add = [NSMutableDictionary dictionary];
    int pitch = aweca_mapPitchToV3(self.pitchRatio);
    if (pitch != 0) {
        add[@"post_process"] = @{ @"pitch": @(pitch) };
    }
    if (allowContext) {
        NSString *ctx = AWECATrim(self.contextText);
        if (ctx.length) add[@"context_texts"] = @[ctx];
    }
    NSString *dialect = [AWECATTSManager canonicalDialect:self.explicitDialect];
    if (dialect.length && [self currentVoiceSupportsDialect]) {
        add[@"explicit_dialect"] = dialect;
    }
    if (self.silenceDurationMs > 0) add[@"silence_duration"] = @(self.silenceDurationMs);
    if (add.count == 0) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:add options:0 error:nil];
    if (!data.length) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (void)applyVolcanoHTTPAuthToRequest:(NSMutableURLRequest *)request {
    if (!request) return;
    NSString *token = AWECATrim(self.accessToken);
    NSString *appID = AWECATrim(self.appID);
    if (token.length > 0) {
        [request setValue:token forHTTPHeaderField:@"X-Api-Key"];
        [request setValue:token forHTTPHeaderField:@"X-Api-Access-Key"];
    }
    if (appID.length > 0) {
        [request setValue:appID forHTTPHeaderField:@"X-Api-App-Id"];
    }
}

- (void)synthesizeVolcanoV3Text:(NSString *)text
                    previewOnly:(BOOL)previewOnly
                     completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion {
    if (!text.length) {
        if (completion) completion(NO, nil, @"请输入要合成的文字");
        return;
    }
    NSString *token = AWECATrim(self.accessToken);
    NSString *appID = AWECATrim(self.appID);
    if (token.length == 0 && appID.length == 0) {
        if (completion) completion(NO, nil, @"请先填写火山 API Key");
        return;
    }

    NSString *speaker = [self volcanoTTS2Speaker];
    // 声音复刻音色（S_xxx / icl_ 开头）必须使用复刻资源 ID（seed-icl-2.0），
    // 否则报 55000000 resource ID is mismatched with speaker related resource
    BOOL isCloneVoice = ([speaker hasPrefix:@"S_"] || [speaker hasPrefix:@"s_"] || [speaker hasPrefix:@"icl_"]);
    NSMutableDictionary *reqParams = [@{
        @"text": text,
        @"speaker": speaker,
        @"audio_params": @{
            @"format": @"mp3",
            @"sample_rate": @24000,
            @"speech_rate": @(aweca_mapRatioToV3(self.speedRatio, 100, -50, 100)),
            @"loudness_rate": @(aweca_mapRatioToV3(self.volumeRatio, 100, -50, 100))
        }
    } mutableCopy];
    // 官方要求：speaker 为复刻音色时需指定 model，指定后不支持语音指令 context_texts
    if (isCloneVoice) reqParams[@"model"] = @"seed-tts-2.0-standard";
    NSString *additions = [self volcanoTTSAdditionsJSONAllowContext:(!isCloneVoice)];
    if (additions.length) reqParams[@"additions"] = additions;

    NSDictionary *body = @{
        @"user": @{ @"uid": appID.length ? appID : @"aweca_user" },
        @"req_params": reqParams
    };

    NSError *jsonErr = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonErr];
    if (jsonErr || !jsonData) {
        if (completion) completion(NO, nil, @"请求构造失败");
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kTTSV3UnidirURL]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = jsonData;
    request.timeoutInterval = 45;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[[NSUUID UUID] UUIDString] forHTTPHeaderField:@"X-Api-Request-Id"];
    [request setValue:(isCloneVoice ? kTTSResourceICL2 : kTTSResourceTTS2) forHTTPHeaderField:@"X-Api-Resource-Id"];
    [self applyVolcanoHTTPAuthToRequest:request];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, nil, [NSString stringWithFormat:@"网络错误: %@", error.localizedDescription]);
            });
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSString *apiCode = AWECAHeader(http.allHeaderFields, @"X-Api-Status-Code");
        NSString *apiMsg = AWECAHeader(http.allHeaderFields, @"X-Api-Message");
        if (apiCode.length && ![apiCode isEqualToString:@"20000000"] && ![apiCode isEqualToString:@"0"]) {
            NSString *hint = apiMsg.length ? apiMsg : @"失败";
            if ([apiCode isEqualToString:@"55000000"]) hint = @"音色与资源不匹配：复刻音色(S_开头)需在火山控制台开通「声音复刻2.0字符版」，且复刻音色不能过期";
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, nil, [NSString stringWithFormat:@"合成错误(%@): %@", apiCode, hint]);
            });
            return;
        }
        if (!data.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, nil, @"服务器无响应");
            });
            return;
        }
        [self parseV3TTSResponse:data text:text previewOnly:previewOnly completion:completion];
    }] resume];
}

#pragma mark - FishAudio

- (NSString *)fishEmotionPrefix {
    NSMutableString *p = [NSMutableString string];
    for (NSString *tag in self.fishEmotionSel) {
        if (![tag isKindOfClass:[NSString class]] || !tag.length) continue;
        [p appendFormat:@"%@ ", tag];
    }
    return p;
}

- (void)synthesizeFishText:(NSString *)text
                previewOnly:(BOOL)previewOnly
                 completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion {
    if (!text.length) {
        if (completion) completion(NO, nil, @"请输入要合成的文字");
        return;
    }
    NSString *key = AWECATrim(self.fishAPIKey);
    if (!key.length) {
        if (completion) completion(NO, nil, @"请先填写 FishAudio API Key");
        return;
    }
    NSString *refID = AWECATrim(self.fishVoiceType);
    if (!refID.length) {
        if (completion) completion(NO, nil, @"请先选择 FishAudio 音色");
        return;
    }

    // 情绪标签直接拼在文本前（s2.x 用 [tag]，s1 用 (tag)，由用户自行维护）
    NSString *fullText = [[self fishEmotionPrefix] stringByAppendingString:text];
    NSString *model = AWECATrim(self.fishModel);
    if (!model.length) model = @"s2.1-pro";

    NSMutableDictionary *body = [@{
        @"text": fullText,
        @"reference_id": refID,
        @"format": @"mp3",
        @"mp3_bitrate": @128,
        @"chunk_length": @200,
    } mutableCopy];
    if ([model isEqualToString:@"s1"]) body[@"normalize"] = @YES;

    NSError *jsonErr = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonErr];
    if (jsonErr || !jsonData) {
        if (completion) completion(NO, nil, @"请求构造失败");
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kFishTTSURL]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = jsonData;
    request.timeoutInterval = 60;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    [request setValue:model forHTTPHeaderField:@"model"];

    NSLog(@"AWECA-Fish: synthesize ref=%@ model=%@ len=%lu", refID, model, (unsigned long)fullText.length);

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, nil, [NSString stringWithFormat:@"网络错误: %@", error.localizedDescription]);
            });
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode != 200 || !data.length) {
            // 错误响应是 JSON：{"message": "..."}
            NSString *msg = @"服务错误";
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                NSString *m = json[@"message"] ?: json[@"detail"];
                if ([m isKindOfClass:[NSString class]] && m.length) msg = m;
            }
            if (!data.length) msg = @"服务器无响应";
            NSLog(@"AWECA-Fish: error %ld %@", (long)http.statusCode, msg);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, nil, [NSString stringWithFormat:@"合成错误(%ld): %@", (long)http.statusCode, msg]);
            });
            return;
        }
        // 成功：响应体即 mp3 原始字节流
        NSLog(@"AWECA-Fish: got audio %lu bytes", (unsigned long)data.length);
        [self finishWithAudioData:data text:text previewOnly:previewOnly completion:completion];
    }] resume];
}

#pragma mark - FishAudio 音色库与头像

+ (NSArray<NSDictionary *> *)fishVoices {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kAWECFishVoices];
    return saved ?: @[];
}

+ (void)saveFishVoices:(NSArray<NSDictionary *> *)voices {
    [[NSUserDefaults standardUserDefaults] setObject:voices ?: @[] forKey:kAWECFishVoices];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSString *)fishAvatarDirPath {
    NSString *dir = [[AWECAUtils audioSavePath] stringByAppendingPathComponent:@"fish_avatars"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSString *)fishAvatarPathForVoiceID:(NSString *)vid {
    if (!vid.length) return nil;
    NSString *safe = [vid stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [[[AWECATTSManager fishAvatarDirPath] stringByAppendingPathComponent:safe] stringByAppendingPathExtension:@"jpg"];
}

- (UIImage *)fishAvatarForVoiceID:(NSString *)vid {
    NSString *p = [self fishAvatarPathForVoiceID:vid];
    if (!p || ![[NSFileManager defaultManager] fileExistsAtPath:p]) return nil;
    return [UIImage imageWithContentsOfFile:p];
}

- (BOOL)saveFishAvatarImage:(UIImage *)image forVoiceID:(NSString *)vid {
    NSString *p = [self fishAvatarPathForVoiceID:vid];
    if (!p || !image) return NO;
    // 中心正方形裁剪
    CGFloat side = MIN(image.size.width, image.size.height);
    CGRect crop = CGRectMake((image.size.width - side) / 2.0, (image.size.height - side) / 2.0, side, side);
    CGImageRef cg = CGImageCreateWithImageInRect(image.CGImage, crop);
    if (!cg) return NO;
    UIImage *square = [UIImage imageWithCGImage:cg scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(cg);
    // 压缩到 256x256 JPEG
    CGSize target = CGSizeMake(256, 256);
    UIGraphicsBeginImageContextWithOptions(target, NO, 1.0);
    [square drawInRect:CGRectMake(0, 0, target.width, target.height)];
    UIImage *resized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    NSData *jpeg = UIImageJPEGRepresentation(resized, 0.82);
    if (!jpeg.length) return NO;
    return [jpeg writeToFile:p atomically:YES];
}

- (void)deleteFishAvatarForVoiceID:(NSString *)vid {
    NSString *p = [self fishAvatarPathForVoiceID:vid];
    if (p) [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
}

#pragma mark - 解析响应

- (void)parseV3TTSResponse:(NSData *)data
                      text:(NSString *)text
               previewOnly:(BOOL)previewOnly
                completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion {
    NSArray *chunks = AWECAJSONObjectsFromData(data);
    if (!chunks.count) {
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([json isKindOfClass:[NSDictionary class]]) chunks = @[json];
    }
    if (!chunks.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(NO, nil, @"响应解析失败");
        });
        return;
    }

    NSMutableData *audioBuf = [NSMutableData data];
    NSString *errMsg = nil;
    NSInteger errCode = 0;
    for (NSDictionary *json in chunks) {
        NSInteger code = [json[@"code"] integerValue];
        BOOL codeOK = (!json[@"code"] || code == 0 || code == 20000000);
        if (!codeOK) {
            errCode = code;
            errMsg = json[@"message"] ?: @"未知错误";
            continue;
        }
        NSString *b64 = json[@"data"];
        if (![b64 isKindOfClass:[NSString class]] || b64.length == 0) {
            b64 = json[@"audio"];
        }
        if ([b64 isKindOfClass:[NSString class]] && b64.length > 0) {
            NSData *part = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (part.length) [audioBuf appendData:part];
        }
    }

    if (audioBuf.length) {
        [self finishWithAudioData:audioBuf text:text previewOnly:previewOnly completion:completion];
        return;
    }

    NSDictionary *last = chunks.lastObject;
    NSString *url = last[@"url"];
    if ([url isKindOfClass:[NSString class]] && url.length > 0) {
        [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *audioData, NSURLResponse *resp, NSError *err) {
            if (err || !audioData.length) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(NO, nil, err.localizedDescription ?: @"音频下载失败");
                });
                return;
            }
            [self finishWithAudioData:audioData text:text previewOnly:previewOnly completion:completion];
        }] resume];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (errMsg.length) {
            NSString *finalMsg = errMsg;
            if (errCode == 55000000) finalMsg = @"音色与资源不匹配：复刻音色(S_开头)需在火山控制台开通「声音复刻2.0字符版」，且复刻音色不能过期";
            if (completion) completion(NO, nil, [NSString stringWithFormat:@"合成错误(%ld): %@", (long)errCode, finalMsg]);
        } else {
            if (completion) completion(NO, nil, @"音频数据为空");
        }
    });
}

- (void)finishWithAudioData:(NSData *)audioData
                       text:(NSString *)text
                previewOnly:(BOOL)previewOnly
                 completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion {

    [AWECAUtils ensureDirectoriesExist];
    NSString *savePath = [[AWECAUtils audioSavePath] stringByAppendingPathComponent:@"tts_result.mp3"];
    BOOL writeOK = [audioData writeToFile:savePath atomically:YES];

    if (!writeOK) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(NO, nil, @"音频保存失败");
        });
        return;
    }

    self.lastSynthesizedPath = savePath;
    [self saveConfig];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (previewOnly) {
            if (completion) completion(YES, savePath, nil);
            return;
        }

        AWECAAudioReplacer *replacer = [AWECAAudioReplacer shared];
        replacer.ttsAudioPath = savePath;
        [replacer saveState];

        NSString *vName = (self.voiceName.length > 0) ? self.voiceName : @"未知音色";

        BOOL hasNormalAudio = replacer.enabled && replacer.replacementAudioPath.length > 0 && !replacer.isUsingTTS;
        if (hasNormalAudio) {
            [self showTTSConflictAlertWithPath:savePath text:text voiceName:vName completion:completion];
        } else {
            __weak AWECAAudioReplacer *weakReplacer = replacer;
            [replacer setReplacementFromTTSPath:savePath text:text voiceName:vName completion:^(BOOL ok) {
                if (completion) {
                    if (ok) {
                        double dur = [AWECAUtils audioDurationAtPath:weakReplacer.replacementAudioPath];
                        [AWECAUtils showToast:@"成功合成！随意录制语音评论即可自动替换" duration:3.0];
                        completion(YES, weakReplacer.replacementAudioPath, [NSString stringWithFormat:@"语音合成成功 (%.1f秒)", dur]);
                    } else {
                        completion(NO, savePath, @"合成成功但设置替换失败");
                    }
                }
            }];
        }
    });
}

#pragma mark - 冲突选择器

- (void)showTTSConflictAlertWithPath:(NSString *)ttsPath
                                text:(NSString *)text
                           voiceName:(NSString *)voiceName
                          completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion {
    UIViewController *topVC = [AWECAUtils topViewController];
    if (!topVC) {
        [[AWECAAudioReplacer shared] setReplacementFromTTSPath:ttsPath text:text voiceName:voiceName completion:^(BOOL ok) {
            if (completion) completion(ok, ttsPath, ok ? @"语音合成成功" : @"设置替换失败");
        }];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"当前已选择普通语音替换"
                                                                  message:@"是否切换为Ai合成语音?"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"使用Ai" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        AWECAAudioReplacer *replacer = [AWECAAudioReplacer shared];
        __weak AWECAAudioReplacer *weakReplacer = replacer;
        [replacer setReplacementFromTTSPath:ttsPath text:text voiceName:voiceName completion:^(BOOL ok) {
            if (completion) {
                if (ok) {
                    double dur = [AWECAUtils audioDurationAtPath:weakReplacer.replacementAudioPath];
                    [AWECAUtils showToast:@"成功合成！随意录制语音评论即可自动替换" duration:3.0];
                    completion(YES, weakReplacer.replacementAudioPath, [NSString stringWithFormat:@"语音合成成功 (%.1f秒)", dur]);
                } else {
                    completion(NO, ttsPath, @"合成成功但设置替换失败");
                }
            }
        }];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"不使用Ai" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (completion) completion(YES, ttsPath, @"合成已保存，当前使用普通语音");
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        if (completion) completion(YES, ttsPath, @"合成已保存");
    }]];

    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = topVC.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(topVC.view.bounds.size.width / 2, topVC.view.bounds.size.height, 0, 0);
    }

    [topVC presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 试听播放

- (void)playAudioAtPath:(NSString *)path {
    if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [AWECAUtils showToast:@"音频文件不存在"];
        return;
    }

    [self stopPlayback];

    NSError *err = nil;
    self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&err];
    if (err || !self.player) {
        [AWECAUtils showToast:@"播放失败"];
        return;
    }

    self.player.delegate = self;

    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    [audioSession setCategory:AVAudioSessionCategoryPlayback
                  withOptions:AVAudioSessionCategoryOptionMixWithOthers
                        error:nil];
    [audioSession setActive:YES error:nil];

    [self.player play];
}

- (void)stopPlayback {
    if (self.player && self.player.isPlaying) {
        [self.player stop];
    }
    self.player = nil;
}

- (BOOL)isPlaying {
    return self.player && self.player.isPlaying;
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    self.player = nil;
}

#pragma mark - 持久化

- (void)saveConfig {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (self.appID) [d setObject:self.appID forKey:kAWECATTSAppID];
    if (self.accessToken) [d setObject:self.accessToken forKey:kAWECATTSAccessToken];
    if (self.voiceType) [d setObject:self.voiceType forKey:kAWECATTSVoiceType];
    if (self.voiceName) [d setObject:self.voiceName forKey:kAWECATTSVoiceName];
    if (self.voiceType) [d setObject:self.voiceType forKey:kAWECATTSVolcanoVoiceType];
    if (self.voiceName) [d setObject:self.voiceName forKey:kAWECATTSVolcanoVoiceName];
    [d setFloat:self.speedRatio forKey:kAWECATTSSpeedRatio];
    [d setFloat:self.volumeRatio forKey:kAWECATTSVolumeRatio];
    [d setFloat:self.pitchRatio forKey:kAWECATTSPitchRatio];
    [d setObject:self.contextText ?: @"" forKey:kAWECATTSContextText];
    [d setObject:[AWECATTSManager canonicalDialect:self.explicitDialect] forKey:kAWECATTSDialect];
    [d setInteger:self.silenceDurationMs forKey:kAWECATTSSilenceMs];
    if (self.lastSynthesizedPath) [d setObject:self.lastSynthesizedPath forKey:kAWECATTSLastPath];
    [d setBool:self.fishEngine forKey:kAWECATTSEngine];
    [d setObject:self.fishAPIKey ?: @"" forKey:kAWECFishAPIKey];
    [d setObject:self.fishModel ?: @"s2.1-pro" forKey:kAWECFishModel];
    [d setObject:self.fishVoiceType ?: @"" forKey:kAWECFishVoiceType];
    [d setObject:self.fishVoiceName ?: @"" forKey:kAWECFishVoiceName];
    [d setObject:self.fishEmotionSel ?: @[] forKey:kAWECFishEmotionSel];
    [d setObject:self.fishEmotionAll ?: @[] forKey:kAWECFishEmotionAll];
    [d synchronize];
}

- (void)loadConfig {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    self.appID = AWECATrim([d objectForKey:kAWECATTSAppID]);
    self.accessToken = AWECATrim([d objectForKey:kAWECATTSAccessToken]);
    self.voiceType = [d objectForKey:kAWECATTSVoiceType];
    self.voiceName = [d objectForKey:kAWECATTSVoiceName];

    float sp = [d floatForKey:kAWECATTSSpeedRatio];
    float vo = [d floatForKey:kAWECATTSVolumeRatio];
    self.speedRatio = (sp > 0.01f) ? sp : 1.0f;
    self.volumeRatio = (vo > 0.01f) ? vo : 1.0f;
    id pitchObj = [d objectForKey:kAWECATTSPitchRatio];
    self.pitchRatio = pitchObj ? [pitchObj floatValue] : 1.0f;
    if (self.pitchRatio < 0.0f) self.pitchRatio = 0.0f;
    if (self.pitchRatio > 2.0f) self.pitchRatio = 2.0f;
    self.contextText = [d objectForKey:kAWECATTSContextText] ?: @"";
    self.explicitDialect = [AWECATTSManager canonicalDialect:[d objectForKey:kAWECATTSDialect]];
    self.silenceDurationMs = [d integerForKey:kAWECATTSSilenceMs];

    self.lastSynthesizedPath = [d objectForKey:kAWECATTSLastPath];

    self.fishEngine = [d boolForKey:kAWECATTSEngine];
    self.fishAPIKey = AWECATrim([d objectForKey:kAWECFishAPIKey]);
    self.fishModel = [d objectForKey:kAWECFishModel] ?: @"s2.1-pro";
    self.fishVoiceType = [d objectForKey:kAWECFishVoiceType];
    self.fishVoiceName = [d objectForKey:kAWECFishVoiceName];
    id selEmo = [d objectForKey:kAWECFishEmotionSel];
    self.fishEmotionSel = [selEmo isKindOfClass:[NSArray class]] ? selEmo : @[];
    id allEmo = [d objectForKey:kAWECFishEmotionAll];
    self.fishEmotionAll = [allEmo isKindOfClass:[NSArray class]] ? allEmo : @[];
}

@end
