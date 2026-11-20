#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface PlayerReader : NSObject
+ (int)permissionFor:(NSString *)bundle ask:(BOOL)ask;
+ (nullable NSDictionary *)read:(NSString *)bundle previousArtworkKey:(nullable NSString *)previous;
+ (void)seek:(NSString *)bundle seconds:(double)seconds;
+ (void)control:(NSString *)bundle command:(NSString *)command;
@end
NS_ASSUME_NONNULL_END
