#import "MenuBarFilter.h"
#import <dlfcn.h>

// macOS 27's menu bar host accepts a process-scoped allow list. Resolve this
// private interface at runtime so a later macOS that changes it still runs the shelf.
@protocol MenuBarConfiguration
- (instancetype)initWithAllowedSystemItems:(NSArray<NSNumber *> *)items
                  allowedBundleIdentifiers:(NSArray<NSString *> *)identifiers;
@end
@protocol MenuBarAssertion
- (void)activateWithConfiguration:(id)configuration completionHandler:(void (^)(NSError *))handler;
- (void)invalidate;
@end

@implementation MenuBarFilter {
    id<MenuBarAssertion> _active;
    id<MenuBarAssertion> _pending;
    NSUInteger _revision;
}

+ (BOOL)isSupported {
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *library = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_LAZY | RTLD_LOCAL);
        available = library &&
            [NSClassFromString(@"MBAssessmentModeConfiguration") instancesRespondToSelector:@selector(initWithAllowedSystemItems:allowedBundleIdentifiers:)] &&
            [NSClassFromString(@"MBAssessmentModeAssertion") instancesRespondToSelector:@selector(activateWithConfiguration:completionHandler:)] &&
            [NSClassFromString(@"MBAssessmentModeAssertion") instancesRespondToSelector:@selector(invalidate)];
    });
    return available;
}

- (void)clear {
    ++_revision;
    [_pending invalidate];
    [_active invalidate];
    _active = nil;
    _pending = nil;
}

- (void)applyAllowedBundles:(NSArray<NSString *> *)identifiers completion:(void (^)(BOOL))completion {
    NSUInteger revision = ++_revision;
    [_pending invalidate];
    _pending = nil;
    if (![MenuBarFilter isSupported]) {
        [self clear];
        completion(NO);
        return;
    }
    void (^finish)(BOOL) = ^(BOOL applied) {
        if (revision != self->_revision) return;
        if (applied) {
            ++self->_revision;
            [self->_active invalidate];
            self->_active = self->_pending;
            self->_pending = nil;
        } else {
            [self clear];
        }
        completion(applied);
    };
    @try {
        id<MenuBarConfiguration> constructor = [NSClassFromString(@"MBAssessmentModeConfiguration") alloc];
        id config = [constructor initWithAllowedSystemItems:@[@0,@1,@2,@3,@4,@5,@6,@7,@8]
                                  allowedBundleIdentifiers:identifiers];
        _pending = [NSClassFromString(@"MBAssessmentModeAssertion") new];
        if (!config || !_pending) { finish(NO); return; }
        [_pending activateWithConfiguration:config completionHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ finish(error == nil); });
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ finish(NO); });
    } @catch (NSException *exception) {
        finish(NO);
    }
}
@end
