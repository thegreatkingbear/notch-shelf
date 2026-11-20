#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface MenuBarFilter : NSObject
+ (BOOL)isSupported;
- (void)applyAllowedBundles:(NSArray<NSString *> *)identifiers
                 completion:(void (^)(BOOL applied))completion;
- (void)clear;
@end
NS_ASSUME_NONNULL_END

#import "PlayerReader.h"
