// 豆包 TTS 管理器
// @cookieodd | github.com/cookieodd | t.me/cookieodd

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

#define kAWECATTSAppID        @"AWECATTSAppID"
#define kAWECATTSAccessToken  @"AWECATTSAccessToken"
#define kAWECATTSVoiceType    @"AWECATTSVoiceType"
#define kAWECATTSVoiceName    @"AWECATTSVoiceName"
#define kAWECATTSSpeedRatio   @"AWECATTSSpeedRatio"
#define kAWECATTSVolumeRatio  @"AWECATTSVolumeRatio"
#define kAWECATTSPitchRatio   @"AWECATTSPitchRatio"
#define kAWECATTSContextText  @"AWECATTSContextText"
#define kAWECATTSDialect      @"AWECATTSDialect"
#define kAWECATTSSilenceMs    @"AWECATTSSilenceMs"
#define kAWECATTSLastPath     @"AWECATTSLastPath"
#define kAWECATTSDialectSpeaker @"zh_female_vv_uranus_bigtts"
#define kAWECATTSVolcanoVoiceType @"AWECATTSVolcanoVoiceType"
#define kAWECATTSVolcanoVoiceName @"AWECATTSVolcanoVoiceName"

// 合成引擎：0=火山（默认） 1=FishAudio
#define kAWECATTSEngine       @"AWECATTSEngine"
// FishAudio（api.fish.audio）
#define kAWECFishAPIKey       @"AWECFishAPIKey"
#define kAWECFishModel        @"AWECFishModel"        // s2.1-pro-free（免费档，默认）/ s2.1-pro / s2-pro / s1
#define kAWECFishVoices       @"AWECFishVoices"       // [{name, voiceType(=reference_id), avatar(emoji 可空), color(索引 可空)}]
#define kAWECFishVoiceType    @"AWECFishVoiceType"    // 当前选中的 reference_id
#define kAWECFishVoiceName    @"AWECFishVoiceName"
#define kAWECFishEmotionSel   @"AWECFishEmotionSel"   // 已勾选的情绪标签（含括号，如 [chuckle]）
#define kAWECFishEmotionAll   @"AWECFishEmotionAll"   // 全部可选情绪标签
#define kAWECFishEmotionNotes @"AWECFishEmotionNotes" // 情绪标签的中文备注（与 All 平行数组，空串=无备注，仅显示用）

#define AWECAProductName   @"声临"
#define AWECAVersion       @"1.4.6"

@class UIImage;

@interface AWECATTSManager : NSObject <AVAudioPlayerDelegate>

+ (instancetype)shared;

@property (nonatomic, copy) NSString *appID;
@property (nonatomic, copy) NSString *accessToken;

// 合成引擎
@property (nonatomic, assign) BOOL fishEngine;   // YES=FishAudio NO=火山

// 火山
@property (nonatomic, copy) NSString *voiceType;
@property (nonatomic, copy) NSString *voiceName;

// FishAudio
@property (nonatomic, copy) NSString *fishAPIKey;
@property (nonatomic, copy) NSString *fishModel;
@property (nonatomic, copy) NSString *fishVoiceType;   // reference_id
@property (nonatomic, copy) NSString *fishVoiceName;
@property (nonatomic, copy) NSArray<NSString *> *fishEmotionSel;
@property (nonatomic, copy) NSArray<NSString *> *fishEmotionAll;
@property (nonatomic, copy) NSArray<NSString *> *fishEmotionNotes;  // 与 fishEmotionAll 平行；越界/缺失=无备注

@property (nonatomic, assign) float speedRatio;
@property (nonatomic, assign) float volumeRatio;
@property (nonatomic, assign) float pitchRatio;

@property (nonatomic, copy) NSString *contextText;
@property (nonatomic, copy) NSString *explicitDialect;
@property (nonatomic, assign) NSInteger silenceDurationMs;

@property (nonatomic, copy, readonly) NSString *lastSynthesizedPath;

- (void)synthesizeText:(NSString *)text
            completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion;

- (void)previewText:(NSString *)text
         completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion;

- (void)synthesizeVolcanoPreviewText:(NSString *)text
                          completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion;

// FishAudio 合成（情绪前缀已含在 text 之外自动拼接；返回 mp3 路径同火山链路）
- (void)synthesizeFishText:(NSString *)text
                previewOnly:(BOOL)previewOnly
                 completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion;

// FishAudio 音色库与头像（头像图片存插件沙盒，256x256 JPEG）
+ (NSArray<NSDictionary *> *)fishVoices;
+ (void)saveFishVoices:(NSArray<NSDictionary *> *)voices;
+ (NSString *)fishAvatarDirPath;
- (UIImage *)fishAvatarForVoiceID:(NSString *)vid;
- (BOOL)saveFishAvatarImage:(UIImage *)image forVoiceID:(NSString *)vid;
- (void)deleteFishAvatarForVoiceID:(NSString *)vid;
// 已勾选情绪标签拼成的前缀（无勾选时返回 @""）
- (NSString *)fishEmotionPrefix;
// 第 idx 个标签的中文备注（无备注返回 @""；越界安全）
- (NSString *)fishEmotionNoteAtIndex:(NSInteger)idx;

- (void)applyVolcanoHTTPAuthToRequest:(NSMutableURLRequest *)request;

- (void)playAudioAtPath:(NSString *)path;
- (void)stopPlayback;
- (BOOL)isPlaying;

- (BOOL)currentVoiceSupportsDialect;
+ (NSString *)canonicalDialect:(NSString *)raw;

- (void)saveConfig;
- (void)loadConfig;

@end
