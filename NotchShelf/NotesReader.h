#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Reads and creates notes in Apple Notes through its scripting dictionary.
/// Call from one background queue; every method sends Apple events and can block.
@interface NotesReader : NSObject
+ (BOOL)isRunning;
+ (int)permissionAsk:(BOOL)ask;
/// The most recently modified notes as dictionaries with id, name, date and locked.
+ (nullable NSArray<NSDictionary *> *)recentNotes:(NSInteger)limit;
/// name, text, locked and editable for one note. A note is editable only when its body
/// is plain lines (div, br and a heading), so saving it as text loses nothing.
+ (nullable NSDictionary *)noteWithID:(NSString *)identifier;
/// Replaces a plain note's body with `text`, one line per paragraph. Refuses when the note's
/// current plain text differs from `expected` (changed elsewhere) or it is no longer plain.
/// Returns the saved plain text.
+ (nullable NSString *)updateNote:(NSString *)identifier expected:(NSString *)expected text:(NSString *)text
                         conflict:(BOOL *)conflict error:(NSString *_Nullable *_Nullable)message;
/// Saves a note in the default folder of the default account and returns its id.
+ (nullable NSString *)createNote:(NSString *)text error:(NSString *_Nullable *_Nullable)message;
+ (void)showNote:(NSString *)identifier;
@end
NS_ASSUME_NONNULL_END
