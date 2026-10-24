// TOS 对象存储上传
// 录音文件识别标准版(volc.bigasr.auc / volc.seedasr.auc)只收公网音频 URL、不收 base64，
// 因此需要先把录音上传到火山 TOS，用预签名 URL 供识别服务下载，识别后删除对象。
// TOS V4 签名规范：https://www.volcengine.com/docs/6349/74839 （单分块上传）
//              https://www.volcengine.com/docs/4726/129226 （预签名 URL）
// @cookieodd 衍生 | github.com/CN-TaylorChen

#import <Foundation/Foundation.h>

#define kAWECATOSAccessKey @"AWECATOSAccessKey"
#define kAWECATOSSecretKey @"AWECATOSSecretKey"
#define kAWECATOSBucket    @"AWECATOSBucket"
#define kAWECATOSRegion    @"AWECATOSRegion"

@interface AWECATOSUploader : NSObject

+ (NSString *)accessKey;
+ (NSString *)secretKey;
+ (NSString *)bucket;
+ (NSString *)region;          // 默认 cn-beijing
+ (BOOL)hasCredentials;        // AK/SK/Bucket 均非空

/// 上传文件到 TOS 并返回预签名下载 URL（默认 1 小时有效）。
/// objectKey 为对象名，建议 "aweca-asr/{uuid}.{ext}"，删除时复用同一名字。
+ (void)uploadFileAtPath:(NSString *)path
              objectKey:(NSString *)objectKey
              completion:(void(^)(NSString *downloadURL, NSError *error))completion;

/// 删除对象（尽力而为，失败静默）
+ (void)deleteObject:(NSString *)objectKey completion:(void(^)(void))completion;

@end
