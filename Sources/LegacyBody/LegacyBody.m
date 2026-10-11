#import "LegacyBody.h"
NSString *YPDecodeBody(NSData *data) {
    if (data.length == 0 || data.length > 2 * 1024 * 1024) return nil;
    @try {
        id value = nil;
        if (data.length > 12 && memcmp((const char *)data.bytes + 2, "streamtyped", 11) == 0) {
            // Apple's legacy Messages format. Only called for locally read attributedBody.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            value = [NSUnarchiver unarchiveObjectWithData:data];
#pragma clang diagnostic pop
        } else {
            value = [NSKeyedUnarchiver unarchivedObjectOfClasses:[NSSet setWithArray:@[
                NSAttributedString.class, NSMutableAttributedString.class, NSString.class,
                NSMutableString.class, NSDictionary.class, NSMutableDictionary.class,
                NSArray.class, NSNumber.class, NSData.class, NSURL.class]] fromData:data error:nil];
        }
        return [value isKindOfClass:NSAttributedString.class] ? [value string] : nil;
    } @catch (NSException *exception) { return nil; }
}
