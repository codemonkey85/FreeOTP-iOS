//
// FreeOTP
//
// Authors: Nathaniel McCallum <npmccallum@redhat.com>
//
// Copyright (C) 2013  Nathaniel McCallum, Red Hat
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "Token.h"
#import "base32.h"

#import <CommonCrypto/CommonHMAC.h>
#import <sys/time.h>

static NSString* decode(const NSString* str) {
    if (str == nil)
        return nil;
    
    str = [str stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    return [str stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
}

static NSString* encode(const NSString* str) {
    if (str == nil)
        return nil;
    str = [str stringByReplacingOccurrencesOfString:@" " withString:@"+"];
    return [str stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
}

static NSData* parseKey(const NSString *secret) {
    uint8_t key[4096];
    if (secret == nil)
        return nil;
    const char *tmp = [secret cStringUsingEncoding:NSASCIIStringEncoding];
    if (tmp == NULL)
        return nil;
    
    int res = base32_decode(tmp, key, sizeof(key));
    if (res < 0 || res == sizeof(key))
        return nil;
    
    return [NSData dataWithBytes:key length:res];
}

static CCHmacAlgorithm parseAlgo(const NSString* algo) {
    static struct {
        const char *name;
        CCHmacAlgorithm num;
    } algomap[] = {
        { "md5", kCCHmacAlgMD5 },
        { "sha1", kCCHmacAlgSHA1 },
        { "sha256", kCCHmacAlgSHA256 },
        { "sha512", kCCHmacAlgSHA512 },
    };
    if (algo == nil)
        return kCCHmacAlgSHA1;
    
    const char *calgo = [algo cStringUsingEncoding:NSUTF8StringEncoding];
    if (calgo == NULL)
        return kCCHmacAlgSHA1;
    for (int i = 0; i < sizeof(algomap) / sizeof(algomap[0]); i++) {
        if (strcasecmp(calgo, algomap[i].name) == 0)
            return algomap[i].num;
    }
    
    return kCCHmacAlgSHA1;
}

static NSInteger parseDigits(const NSString* digits) {
    if (digits == nil)
        return 6;
    
    NSInteger val = [digits integerValue];
    if (val != 6 && val != 8)
        return 6;
    
    return val;
}

static inline const char* unparseAlgo(CCHmacAlgorithm algo) {
    switch (algo) {
        case kCCHmacAlgMD5:
            return "md5";
        case kCCHmacAlgSHA256:
            return "sha256";
        case kCCHmacAlgSHA512:
            return "sha512";
        case kCCHmacAlgSHA1:
        default:
            return "sha1";
    }
}

static NSString* unparseKey(const NSData* key) {
    char buf[8192];
    
    int res = base32_encode([key bytes], (int) [key length], buf, sizeof(buf));
    if (res < 0 || res >= sizeof(buf))
        return nil;
    
    return [NSString stringWithUTF8String:buf];
}

static inline size_t getDigestLength(CCHmacAlgorithm algo) {
    switch (algo) {
        case kCCHmacAlgMD5:
            return CC_MD5_DIGEST_LENGTH;
        case kCCHmacAlgSHA256:
            return CC_SHA256_DIGEST_LENGTH;
        case kCCHmacAlgSHA512:
            return CC_SHA512_DIGEST_LENGTH;
        case kCCHmacAlgSHA1:
        default:
            return CC_SHA1_DIGEST_LENGTH;
    }
}

static NSString* getHOTP(CCHmacAlgorithm algo, uint8_t digits, NSData* key, uint64_t counter) {
#ifdef __LITTLE_ENDIAN__
    // Network byte order
    counter = (((uint64_t) htonl(counter)) << 32) + htonl(counter >> 32);
#endif
    
    // Create digits divisor
    uint32_t div = 1;
    for (int i = digits; i > 0; i--)
        div *= 10;
    
    // Create the HMAC
    uint8_t digest[getDigestLength(algo)];
    CCHmac(algo, [key bytes], [key length], &counter, sizeof(counter), digest);

    // Truncate
    uint32_t binary;
    uint32_t off = digest[sizeof(digest) - 1] & 0xf;
    binary  = (digest[off + 0] & 0x7f) << 0x18;
    binary |= (digest[off + 1] & 0xff) << 0x10;
    binary |= (digest[off + 2] & 0xff) << 0x08;
    binary |= (digest[off + 3] & 0xff) << 0x00;
    binary  = binary % div;

    return [NSString stringWithFormat:[NSString stringWithFormat:@"%%0%hhulu", digits], binary];
}

@implementation Token
{
    NSString* issuerInt;
	CCHmacAlgorithm algo;
    NSData*   key;
    uint64_t counter;
    uint32_t period;
}

- (id)initWithURL:(NSURL*)url {
    return [self initWithURL:url internal:NO];
}

- (id)initWithURL:(NSURL*)url internal:(BOOL)internal {
    if (!(self = [super init]))
        return nil;
    
    NSString* scheme = [url scheme];
    if (scheme == nil || ![scheme isEqualToString:@"otpauth"])
        return nil;
    
    _type = [url host];
    if (_type == nil ||
        (![_type isEqualToString:@"totp"] &&
         ![_type isEqualToString:@"hotp"]))
        return nil;
    
    // Get the path and strip it of its leading '/'
    NSString* path = [url path];
    if (path == nil)
        return nil;
    while ([path hasPrefix:@"/"])
        path = [path substringFromIndex:1];
    if ([path length] == 0)
        return nil;
    
    // Get issuer and label
    NSArray* array = [path componentsSeparatedByString:@":"];
    if (array == nil || [array count] == 0)
        return nil;
    if ([array count] > 1) {
        _issuerDefault = decode([array objectAtIndex:0]);
        _labelDefault = decode([array objectAtIndex:1]);
    } else {
        _issuerDefault = @"";
        _labelDefault = decode([array objectAtIndex:0]);
    }

    // Parse query
    NSMutableDictionary *query = [[NSMutableDictionary alloc] init];
    array = [[url query] componentsSeparatedByString:@"&"];
    for (NSString *kv in array) {
        NSArray *tmp = [kv componentsSeparatedByString:@"="];
        if (tmp.count != 2)
            continue;
        [query setValue:decode([tmp objectAtIndex:1]) forKey:[tmp objectAtIndex:0]];
    }
    
    // Get key
    key = parseKey([query objectForKey:@"secret"]);
    if (key == nil)
        return nil;
    
    // Get internal issuer
    issuerInt = [query objectForKey:@"issuer"];
    if (issuerInt == nil)
        issuerInt = _issuerDefault;

    // Get algorithm and digits
    algo = parseAlgo([query objectForKey:@"algorithm"]);
    _digits = parseDigits([query objectForKey:@"digits"]);

    // Get period
    NSString *p = [query objectForKey:@"period"];
    period = p != nil ? (int) [p integerValue] : 30;
    if (period == 0)
        period = 30;

    // Get counter
    if ([_type isEqualToString:@"hotp"]) {
        NSString *c = [query objectForKey:@"counter"];
        counter = c != nil ? [c longLongValue] : 0;
    }

    // Get altnames
    if (internal) {
        _issuer = [query objectForKey:@"issueralt"];
        _label = [query objectForKey:@"labelalt"];
    }
    
    return self;
}

- (id)initWithString:(NSString*)string {
    return [self initWithURL:[[NSURL alloc] initWithString:string] internal:NO];
}

- (id)initWithString:(NSString*)string internal:(BOOL)internal {
    return [self initWithURL:[[NSURL alloc] initWithString:string] internal:internal];
}

- (NSString*)description {
    NSString *tmp = [NSString
            stringWithFormat:@"otpauth://%@/%@:%@?algorithm=%s&digits=%lu&secret=%@&issuer=%@&period=%u",
            _type, encode(_issuerDefault), encode(_labelDefault), unparseAlgo(algo),
            (unsigned long) _digits, unparseKey(key), encode(issuerInt), period];
    if (tmp == nil)
        return nil;

    if (_issuer != nil)
        tmp = [NSString stringWithFormat:@"%@&issueralt=%@", tmp, _issuer];

    if (_label != nil)
        tmp = [NSString stringWithFormat:@"%@&labelalt=%@", tmp, _label];

    if ([_type isEqualToString:@"hotp"])
        return [NSString stringWithFormat:@"%@&counter=%llu", tmp, counter];
    
    return tmp;
}

- (NSString*)issuer {
    if (_issuer == nil)
        return _issuerDefault;
    return _issuer;
}

- (NSString*)label {
    if (_label == nil)
        return _labelDefault;
    return _label;
}

- (TokenCode*)code {
    time_t now = time(NULL);
    if (now == (time_t) -1)
        now = 0;

    if ([_type isEqualToString:@"hotp"]) {
        NSString* code = getHOTP(algo, _digits, key, counter++);
        return [[TokenCode alloc] initWithCode:code startTime:now endTime:now + period];
    }

    TokenCode* next = [[TokenCode alloc] initWithCode:getHOTP(algo, _digits, key, now / period + 1)
                                            startTime:now / period * period + period
                                              endTime:now / period * period + period + period];
    return [[TokenCode alloc] initWithCode:getHOTP(algo, _digits, key, now / period)
                                 startTime:now / period * period
                                   endTime:now / period * period + period
                             nextTokenCode:next];
}

- (NSString*)uid {
    return [NSString stringWithFormat:@"%@:%@", issuerInt, _labelDefault];
}
@end
