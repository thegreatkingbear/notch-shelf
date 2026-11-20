#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Reads and creates notes in Apple Notes through its scripting dictionary.
/// Call from one background queue; every method sends Apple events and can block.
@interface NotesReader : NSObject
+ (BOOL)isRunning;
+ (int)permissionAsk:(BOOL)ask;
/// The most recently modified notes as dictionaries with id, name, date and locked.
+ (nullable NSArray<NSDictionary *> *)recentNotes:(NSInteger)limit;
/// name, text and locked for one note.
+ (nullable NSDictionary *)noteWithID:(NSString *)identifier;
/// Saves a note in the default folder of the default account and returns its id.
+ (nullable NSString *)createNote:(NSString *)text error:(NSString *_Nullable *_Nullable)message;
+ (void)showNote:(NSString *)identifier;
@end
NS_ASSUME_NONNULL_END
