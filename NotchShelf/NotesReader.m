#import "NotesReader.h"
#import <AppKit/AppKit.h>
#import <ScriptingBridge/ScriptingBridge.h>

static NSString *const NotesBundle = @"com.apple.Notes";

// Notes implements these selectors through its scripting dictionary.
@protocol NotesNote
- (NSString *)id;
- (NSString *)name;
- (NSString *)plaintext;
- (NSDate *)modificationDate;
- (BOOL)passwordProtected;
- (void)show;
@end
@protocol NotesFolder
- (SBElementArray *)notes;
@end
@protocol NotesAccount
- (SBObject<NotesFolder> *)defaultFolder;
@end
@protocol NotesApplication
- (SBElementArray *)notes;
- (SBObject<NotesAccount> *)defaultAccount;
@end

static NSString *escapeHTML(NSString *text) {
    NSMutableString *html = [NSMutableString string];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
        if ([character isEqual:@"&"]) [html appendString:@"&amp;"];
        else if ([character isEqual:@"<"]) [html appendString:@"&lt;"];
        else if ([character isEqual:@">"]) [html appendString:@"&gt;"];
        else if ([character isEqual:@"\""]) [html appendString:@"&quot;"];
        else [html appendString:character];
    }];
    return html;
}

@implementation NotesReader
+ (BOOL)isRunning {
    return [NSRunningApplication runningApplicationsWithBundleIdentifier:NotesBundle].count > 0;
}

+ (int)permissionAsk:(BOOL)ask {
    NSAppleEventDescriptor *target = [NSAppleEventDescriptor descriptorWithBundleIdentifier:NotesBundle];
    return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask);
}

+ (SBApplication<NotesApplication> *)app {
    if (![self isRunning]) return nil;
    SBApplication<NotesApplication> *app = (id)[SBApplication applicationWithBundleIdentifier:NotesBundle];
    app.timeout = 600; // Ticks. A large iCloud library can take a few seconds to enumerate.
    return app;
}

+ (NSArray<NSDictionary *> *)recentNotes:(NSInteger)limit {
    @try {
        SBElementArray *notes = [self app].notes;
        if (!notes) return nil;
        // One Apple event per property for the whole library.
        NSArray *ids = [notes arrayByApplyingSelector:@selector(id)];
        NSArray *names = [notes arrayByApplyingSelector:@selector(name)];
        NSArray *dates = [notes arrayByApplyingSelector:@selector(modificationDate)];
        NSArray *locks = [notes arrayByApplyingSelector:@selector(passwordProtected)];
        if (!ids || ids.count != names.count || ids.count != dates.count) return nil;
        NSMutableArray<NSDictionary *> *rows = [NSMutableArray arrayWithCapacity:ids.count];
        for (NSUInteger i = 0; i < ids.count; i++) {
            if (![ids[i] isKindOfClass:NSString.class]) continue;
            NSDate *date = [dates[i] isKindOfClass:NSDate.class] ? dates[i] : NSDate.distantPast;
            NSString *name = [names[i] isKindOfClass:NSString.class] ? names[i] : @"";
            BOOL locked = i < locks.count && [locks[i] respondsToSelector:@selector(boolValue)] && [locks[i] boolValue];
            [rows addObject:@{@"id": ids[i], @"name": name, @"date": date, @"locked": @(locked)}];
        }
        [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"date"] compare:a[@"date"]];
        }];
        return limit < (NSInteger)rows.count ? [rows subarrayWithRange:NSMakeRange(0, limit)] : rows;
    } @catch (NSException *exception) { return nil; }
}

+ (NSDictionary *)noteWithID:(NSString *)identifier {
    @try {
        SBObject<NotesNote> *note = [[self app].notes objectWithID:identifier];
        if (!note) return nil;
        NSString *name = note.name;
        if (!name) return nil;
        BOOL locked = note.passwordProtected;
        NSString *text = locked ? @"" : (note.plaintext ?: @"");
        return @{@"name": name, @"text": text, @"locked": @(locked)};
    } @catch (NSException *exception) { return nil; }
}

+ (NSString *)createNote:(NSString *)text error:(NSString **)message {
    @try {
        SBApplication<NotesApplication> *app = [self app];
        SBObject<NotesFolder> *folder = app.defaultAccount.defaultFolder;
        if (!folder) return nil;
        NSMutableArray *lines = [NSMutableArray array];
        for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            [lines addObject:[NSString stringWithFormat:@"<div>%@</div>", line.length ? escapeHTML(line) : @"<br>"]];
        }
        Class noteClass = [app classForScriptingClass:@"note"];
        SBObject<NotesNote> *note = [[noteClass alloc] initWithProperties:@{@"body": [lines componentsJoinedByString:@""]}];
        [folder.notes addObject:note];
        NSError *error = note.lastError ?: app.lastError;
        if (error) {
            if (message) *message = error.localizedDescription;
            return nil;
        }
        return note.id;
    } @catch (NSException *exception) {
        if (message) *message = exception.reason;
        return nil;
    }
}

+ (void)showNote:(NSString *)identifier {
    @try {
        SBApplication<NotesApplication> *app = [self app];
        [[app.notes objectWithID:identifier] show];
        [app activate];
    } @catch (NSException *exception) {}
}
@end
