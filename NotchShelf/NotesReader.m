#import "NotesReader.h"
#import <AppKit/AppKit.h>
#import <ScriptingBridge/ScriptingBridge.h>

static NSString *const NotesBundle = @"com.apple.Notes";

// Notes implements these selectors through its scripting dictionary.
@protocol NotesNote
- (NSString *)id;
- (NSString *)name;
- (NSString *)plaintext;
- (NSString *)body;
- (void)setBody:(NSString *)body;
- (NSDate *)modificationDate;
- (BOOL)passwordProtected;
- (void)show;
@end
@protocol NotesFolder
- (NSString *)id;
- (NSString *)name;
- (SBObject *)container;
- (SBElementArray *)notes;
@end
@protocol NotesAccount
- (NSString *)id;
- (SBElementArray *)folders;
- (SBObject<NotesFolder> *)defaultFolder;
@end
@protocol NotesApplication
- (SBElementArray *)notes;
- (SBElementArray *)accounts;
- (SBObject<NotesAccount> *)defaultAccount;
@end

// The app's note list includes each account's Recently Deleted folder, which scripting
// doesn't mark. Recognise it by Notes' own localized names for that folder.
static NSSet<NSString *> *trashFolderNames(void) {
    static NSSet *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableSet *set = [NSMutableSet setWithArray:@[@"Recently Deleted", @"최근 삭제된 항목", @"最近削除した項目",
            @"最近删除", @"最近刪除", @"Suppr. récentes", @"Zuletzt gelöscht", @"Недавно удаленные"]];
        NSData *data = [NSData dataWithContentsOfFile:@"/System/Library/PrivateFrameworks/NotesShared.framework/Resources/Localizable.loctable"];
        NSDictionary *table = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil] : nil;
        if ([table isKindOfClass:NSDictionary.class]) {
            for (NSDictionary *strings in table.allValues) {
                if (![strings isKindOfClass:NSDictionary.class]) continue;
                id name = strings[@"Recently Deleted"];
                if ([name isKindOfClass:NSString.class]) [set addObject:name];
            }
        }
        names = set;
    });
    return names;
}

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

// Bodies larger than this hold inline images; never treat them as plain.
static const NSUInteger PlainBodyLimit = 200000;

static BOOL isPlainBody(NSString *html) {
    if (html.length > PlainBodyLimit) return NO;
    static NSRegularExpression *tags;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ tags = [NSRegularExpression regularExpressionWithPattern:@"<\\s*/?\\s*([A-Za-z0-9]+)" options:0 error:nil]; });
    NSSet *allowed = [NSSet setWithArray:@[@"div", @"br", @"h1"]];
    __block BOOL plain = YES;
    [tags enumerateMatchesInString:html options:0 range:NSMakeRange(0, html.length)
                        usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
        if (![allowed containsObject:[html substringWithRange:[match rangeAtIndex:1]].lowercaseString]) { plain = NO; *stop = YES; }
    }];
    if (!plain) return NO;
    // Only the first line may be a heading; htmlForText restores just that one.
    NSUInteger headings = [html componentsSeparatedByString:@"<h1>"].count - 1;
    return headings == 0 || (headings == 1 && [html hasPrefix:@"<div><h1>"]);
}

static NSString *htmlForText(NSString *text, BOOL heading) {
    NSMutableString *html = [NSMutableString string];
    __block BOOL first = YES;
    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        if (!line.length) [html appendString:@"<div><br></div>"];
        else if (first && heading) [html appendFormat:@"<div><h1>%@</h1></div>", escapeHTML(line)];
        else [html appendFormat:@"<div>%@</div>", escapeHTML(line)];
        first = NO;
    }];
    return html.length ? html : @"<div><br></div>";
}

static NSString *normalized(NSString *text) {
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

@implementation NotesReader
/// Ids of notes waiting in a Recently Deleted folder, which belongs directly to an account.
+ (NSSet<NSString *> *)deletedNoteIDs:(SBApplication<NotesApplication> *)app {
    NSMutableSet *ids = [NSMutableSet set];
    NSSet *trash = trashFolderNames();
    for (SBObject<NotesAccount> *account in app.accounts) {
        NSString *accountID = account.id;
        SBElementArray *folders = account.folders;
        NSArray *names = [folders arrayByApplyingSelector:@selector(name)];
        for (NSUInteger i = 0; i < names.count && i < folders.count; i++) {
            if (![trash containsObject:names[i]]) continue;
            SBObject<NotesFolder> *folder = folders[i];
            id parent = [folder.container get];
            if (![parent respondsToSelector:@selector(id)] || ![[parent id] isEqual:accountID]) continue;
            NSArray *noteIDs = [folder.notes arrayByApplyingSelector:@selector(id)];
            if (noteIDs) [ids addObjectsFromArray:noteIDs];
        }
    }
    return ids;
}

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
        NSSet *deleted = [self deletedNoteIDs:[self app]];
        NSMutableArray<NSDictionary *> *rows = [NSMutableArray arrayWithCapacity:ids.count];
        for (NSUInteger i = 0; i < ids.count; i++) {
            if (![ids[i] isKindOfClass:NSString.class] || [deleted containsObject:ids[i]]) continue;
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
        BOOL editable = !locked && isPlainBody(note.body ?: @"<img>");
        return @{@"name": name, @"text": text, @"locked": @(locked), @"editable": @(editable)};
    } @catch (NSException *exception) { return nil; }
}

+ (NSString *)createNote:(NSString *)text error:(NSString **)message {
    @try {
        SBApplication<NotesApplication> *app = [self app];
        SBObject<NotesFolder> *folder = app.defaultAccount.defaultFolder;
        if (!folder) return nil;
        Class noteClass = [app classForScriptingClass:@"note"];
        SBObject<NotesNote> *note = [[noteClass alloc] initWithProperties:@{@"body": htmlForText(text, NO)}];
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

+ (NSString *)updateNote:(NSString *)identifier expected:(NSString *)expected text:(NSString *)text
                conflict:(BOOL *)conflict error:(NSString **)message {
    if (conflict) *conflict = NO;
    @try {
        SBApplication<NotesApplication> *app = [self app];
        SBObject<NotesNote> *note = [app.notes objectWithID:identifier];
        NSString *body = note.body;
        if (!body) return nil;
        if (note.passwordProtected || !isPlainBody(body) || [[self deletedNoteIDs:app] containsObject:identifier] || ![normalized(note.plaintext ?: @"") isEqual:normalized(expected)]) {
            if (conflict) *conflict = YES;
            return nil;
        }
        BOOL heading = [body rangeOfString:@"<h1>" options:NSCaseInsensitiveSearch].location != NSNotFound;
        note.body = htmlForText(text, heading);
        NSError *error = note.lastError ?: app.lastError;
        if (error) {
            if (message) *message = error.localizedDescription;
            return nil;
        }
        return note.plaintext ?: text;
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
