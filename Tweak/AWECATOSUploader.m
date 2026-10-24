// TOS 对象存储上传实现
// @cookieodd 衍生 | github.com/CN-TaylorChen

#import "AWECATOSUploader.h"
#import <CommonCrypto/CommonCrypto.h>

// sha256("")，空 body 的 GET/DELETE 请求用它作 payload hash
static NSString *const kAWECAEmptySHA256 = @"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

// 从 TOS 错误响应 XML 里取 <Tag>内容</Tag>
static NSString *AWECATOSXMLElement(NSString *xml, NSString *tag) {
    NSString *open = [NSString stringWithFormat:@"<%@>", tag];
    NSString *close = [NSString stringWithFormat:@"</%@>", tag];
    NSRange o = [xml rangeOfString:open];
    if (o.location == NSNotFound) return nil;
    NSRange c = [xml rangeOfString:close];
    if (c.location == NSNotFound) return nil;
    NSInteger start = o.location + o.length;
    if (c.location < start) return nil;
    return [xml substringWithRange:NSMakeRange(start, c.location - start)];
}

@implementation AWECATOSUploader

#pragma mark - 配置

+ (NSString *)trim:(NSString *)s {
    if (![s isKindOfClass:[NSString class]]) return @"";
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

+ (NSString *)accessKey { return [self trim:[[NSUserDefaults standardUserDefaults] stringForKey:kAWECATOSAccessKey]]; }
+ (NSString *)secretKey { return [self trim:[[NSUserDefaults standardUserDefaults] stringForKey:kAWECATOSSecretKey]]; }
+ (NSString *)bucket    { return [self trim:[[NSUserDefaults standardUserDefaults] stringForKey:kAWECATOSBucket]]; }

+ (NSString *)region {
    NSString *r = [self trim:[[NSUserDefaults standardUserDefaults] stringForKey:kAWECATOSRegion]].lowercaseString;
    if (!r.length) return @"cn-beijing";
    // 容忍用户粘贴 endpoint / tos-cn-beijing 形式
    NSRange dot = [r rangeOfString:@".volces.com"];
    if (dot.location != NSNotFound) r = [r substringToIndex:dot.location];
    if ([r hasPrefix:@"tos-"]) r = [r substringFromIndex:4];
    return r.length ? r : @"cn-beijing";
}

+ (BOOL)hasCredentials {
    return self.accessKey.length > 0 && self.secretKey.length > 0 && self.bucket.length > 0;
}

#pragma mark - 密码学基元

+ (NSString *)hexOfData:(NSData *)data {
    const uint8_t *bytes = data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

+ (NSData *)sha256OfData:(NSData *)data {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return [NSData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH];
}

+ (NSData *)hmacSHA256:(NSData *)key message:(NSString *)message {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, message.UTF8String, strlen(message.UTF8String), digest);
    return [NSData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH];
}

// RFC3986 编码；keepSlash=NO 时连 '/' 一起编码（用于 query value）
+ (NSString *)uriEncode:(NSString *)s keepSlash:(BOOL)keepSlash {
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"-._~"];
    if (keepSlash) [allowed addCharactersInString:@"/"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

+ (void)currentDates:(NSString **)iso8601 datestamp:(NSString **)datestamp {
    NSDate *now = [NSDate date];
    static NSDateFormatter *isoF = nil, *dsF = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSLocale *posix = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        NSTimeZone *gmt = [NSTimeZone timeZoneWithName:@"GMT"];
        isoF = [[NSDateFormatter alloc] init];
        isoF.locale = posix; isoF.timeZone = gmt;
        isoF.dateFormat = @"yyyyMMdd'T'HHmmss'Z'";
        dsF = [[NSDateFormatter alloc] init];
        dsF.locale = posix; dsF.timeZone = gmt;
        dsF.dateFormat = @"yyyyMMdd";
    });
    if (iso8601) *iso8601 = [isoF stringFromDate:now];
    if (datestamp) *datestamp = [dsF stringFromDate:now];
}

#pragma mark - 签名

/// TOS V4 签名：待签字符串 = 算法名 \n ISO时间 \n scope \n sha256(规范请求)
/// 密钥派生（注意：内层是 HMAC(SK, date)，SK 前不加前缀）
+ (NSString *)signatureForMethod:(NSString *)method
                     canonicalURI:(NSString *)uri
                  canonicalQuery:(NSString *)query
                 canonicalHeaders:(NSString *)headers
                    signedHeaders:(NSString *)signedHeaders
                     payloadHash:(NSString *)payloadHash
                           region:(NSString *)region
                             date:(NSString *)iso
                         datestamp:(NSString *)ds {
    NSString *canonicalRequest = [NSString stringWithFormat:@"%@\n%@\n%@\n%@\n%@\n%@",
                                  method, uri, query, headers, signedHeaders, payloadHash];
    NSString *scope = [NSString stringWithFormat:@"%@/%@/tos/request", ds, region];
    NSData *canonHash = [self sha256OfData:[canonicalRequest dataUsingEncoding:NSUTF8StringEncoding]];
    NSString *stringToSign = [NSString stringWithFormat:@"TOS4-HMAC-SHA256\n%@\n%@\n%@",
                              iso, scope, [self hexOfData:canonHash]];
    NSData *kDate    = [self hmacSHA256:[self.secretKey dataUsingEncoding:NSUTF8StringEncoding] message:ds];
    NSData *kRegion  = [self hmacSHA256:kDate message:region];
    NSData *kService = [self hmacSHA256:kRegion message:@"tos"];
    NSData *kSigning = [self hmacSHA256:kService message:@"request"];
    return [self hexOfData:[self hmacSHA256:kSigning message:stringToSign]];
}

+ (NSString *)hostForBucket:(NSString *)bucket region:(NSString *)region {
    return [NSString stringWithFormat:@"%@.tos-%@.volces.com", bucket, region];
}

+ (NSString *)canonicalURIForKey:(NSString *)objectKey {
    // 分段编码，保留路径分隔符
    NSMutableArray *segs = [NSMutableArray array];
    for (NSString *seg in [objectKey componentsSeparatedByString:@"/"]) {
        if (!seg.length) continue;
        [segs addObject:[self uriEncode:seg keepSlash:YES]];
    }
    return [NSString stringWithFormat:@"/%@", [segs componentsJoinedByString:@"/"]];
}

#pragma mark - 上传（PUT + Authorization 头）

+ (void)uploadFileAtPath:(NSString *)path
              objectKey:(NSString *)objectKey
              completion:(void(^)(NSString *downloadURL, NSError *error))completion {
    if (!completion) return;
    if (![self hasCredentials]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [NSError errorWithDomain:@"AWECATOS" code:4001
                userInfo:@{NSLocalizedDescriptionKey: @"未填写 TOS AK/SK/Bucket（设置 → 识别）"}]);
        });
        return;
    }
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [NSError errorWithDomain:@"AWECATOS" code:4002
                userInfo:@{NSLocalizedDescriptionKey: @"录音文件读取失败"}]);
        });
        return;
    }

    NSString *region = [self region];
    NSString *bucket = self.bucket;
    NSString *host = [self hostForBucket:bucket region:region];
    NSString *uri = [self canonicalURIForKey:objectKey];
    NSString *payloadHash = [self hexOfData:[self sha256OfData:data]];

    NSString *iso = nil, *ds = nil;
    [self currentDates:&iso datestamp:&ds];
    NSString *headers = [NSString stringWithFormat:@"host:%@\nx-tos-content-sha256:%@\nx-tos-date:%@\n",
                         host, payloadHash, iso];
    NSString *signedHeaders = @"host;x-tos-content-sha256;x-tos-date";
    NSString *sig = [self signatureForMethod:@"PUT"
                                 canonicalURI:uri
                              canonicalQuery:@""
                             canonicalHeaders:headers
                                signedHeaders:signedHeaders
                                 payloadHash:payloadHash
                                       region:region
                                         date:iso
                                     datestamp:ds];
    NSString *auth = [NSString stringWithFormat:@"TOS4-HMAC-SHA256 Credential=%@/%@/%@/tos/request, SignedHeaders=%@, Signature=%@",
                      self.accessKey, ds, region, signedHeaders, sig];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[NSString stringWithFormat:@"https://%@%@", host, uri]]];
    req.HTTPMethod = @"PUT";
    req.HTTPBody = data;
    req.timeoutInterval = 30;
    [req setValue:auth forHTTPHeaderField:@"Authorization"];
    [req setValue:payloadHash forHTTPHeaderField:@"x-tos-content-sha256"];
    [req setValue:iso forHTTPHeaderField:@"x-tos-date"];
    [req setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)r;
        void (^finish)(NSString *, NSError *) = ^(NSString *url, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(url, err); });
        };
        if (e) { finish(nil, e); return; }
        if (http.statusCode < 200 || http.statusCode >= 300) {
            NSString *detail = [NSString stringWithFormat:@"TOS 上传失败 (HTTP %ld)", (long)http.statusCode];
            if (d.length) {
                NSString *body = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
                NSString *code = AWECATOSXMLElement(body, @"Code");
                NSString *msg = AWECATOSXMLElement(body, @"Message");
                if (code.length) detail = [detail stringByAppendingFormat:@" [%@]", code];
                if (msg.length) detail = [detail stringByAppendingFormat:@" %@", msg];
            }
            finish(nil, [NSError errorWithDomain:@"AWECATOS" code:http.statusCode
                userInfo:@{NSLocalizedDescriptionKey: detail}]);
            return;
        }
        finish([self presignedURLForKey:objectKey expires:3600], nil);
    }] resume];
}

#pragma mark - 预签名 GET URL

/// 预签名：CanonicalQuery 不含 X-Tos-Signature，HashedPayload 用 UNSIGNED-PAYLOAD
+ (NSString *)presignedURLForKey:(NSString *)objectKey expires:(NSInteger)expires {
    NSString *region = [self region];
    NSString *bucket = self.bucket;
    NSString *host = [self hostForBucket:bucket region:region];
    NSString *uri = [self canonicalURIForKey:objectKey];
    NSString *iso = nil, *ds = nil;
    [self currentDates:&iso datestamp:&ds];

    NSDictionary *params = @{
        @"X-Tos-Algorithm": @"TOS4-HMAC-SHA256",
        @"X-Tos-Credential": [NSString stringWithFormat:@"%@/%@/%@/tos/request", self.accessKey, ds, region],
        @"X-Tos-Date": iso,
        @"X-Tos-Expires": [@(expires) stringValue],
        @"X-Tos-SignedHeaders": @"host",
    };
    NSMutableString *query = [NSMutableString string];
    for (NSString *k in [[params allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (query.length) [query appendString:@"&"];
        [query appendFormat:@"%@=%@", [self uriEncode:k keepSlash:NO], [self uriEncode:params[k] keepSlash:NO]];
    }
    NSString *headers = [NSString stringWithFormat:@"host:%@\n", host];
    NSString *sig = [self signatureForMethod:@"GET"
                                 canonicalURI:uri
                              canonicalQuery:query
                             canonicalHeaders:headers
                                signedHeaders:@"host"
                                 payloadHash:@"UNSIGNED-PAYLOAD"
                                       region:region
                                         date:iso
                                     datestamp:ds];
    return [NSString stringWithFormat:@"https://%@%@?%@&X-Tos-Signature=%@", host, uri, query, sig];
}

#pragma mark - 删除（DELETE）

+ (void)deleteObject:(NSString *)objectKey completion:(void(^)(void))completion {
    if (!objectKey.length || ![self hasCredentials]) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
        return;
    }
    NSString *region = [self region];
    NSString *bucket = self.bucket;
    NSString *host = [self hostForBucket:bucket region:region];
    NSString *uri = [self canonicalURIForKey:objectKey];
    NSString *iso = nil, *ds = nil;
    [self currentDates:&iso datestamp:&ds];

    NSString *headers = [NSString stringWithFormat:@"host:%@\nx-tos-content-sha256:%@\nx-tos-date:%@\n",
                         host, kAWECAEmptySHA256, iso];
    NSString *signedHeaders = @"host;x-tos-content-sha256;x-tos-date";
    NSString *sig = [self signatureForMethod:@"DELETE"
                                 canonicalURI:uri
                              canonicalQuery:@""
                             canonicalHeaders:headers
                                signedHeaders:signedHeaders
                                 payloadHash:kAWECAEmptySHA256
                                       region:region
                                         date:iso
                                     datestamp:ds];
    NSString *auth = [NSString stringWithFormat:@"TOS4-HMAC-SHA256 Credential=%@/%@/%@/tos/request, SignedHeaders=%@, Signature=%@",
                      self.accessKey, ds, region, signedHeaders, sig];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[NSString stringWithFormat:@"https://%@%@", host, uri]]];
    req.HTTPMethod = @"DELETE";
    req.timeoutInterval = 15;
    [req setValue:auth forHTTPHeaderField:@"Authorization"];
    [req setValue:kAWECAEmptySHA256 forHTTPHeaderField:@"x-tos-content-sha256"];
    [req setValue:iso forHTTPHeaderField:@"x-tos-date"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        (void)d; (void)e;
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
    }] resume];
}

@end
