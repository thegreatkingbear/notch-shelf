#import "PlayerReader.h"
#import <AppKit/AppKit.h>
#import <ScriptingBridge/ScriptingBridge.h>

// Music and Spotify implement these selectors through their scripting dictionaries.
@protocol MusicArtwork
- (id)rawData;
- (id)data;
@end
@protocol PlayerTrack
- (NSString *)name;
- (NSString *)artist;
- (NSString *)album;
- (double)duration; // Music returns seconds.
- (NSString *)artworkUrl;
- (SBElementArray *)artworks;
@end
@protocol MusicPlayer
- (unsigned int)playerState;
- (SBObject<PlayerTrack> *)currentTrack;
- (double)playerPosition;
- (void)setPlayerPosition:(double)value;
- (void)playpause;
- (void)nextTrack;
- (void)previousTrack;
@end

// Music can return an Apple event object specifier for rawData, and a
// picture descriptor for data. Resolve either representation before decoding.
static NSData *imageData(id value) {
    if ([value isKindOfClass:SBObject.class]) value = [(SBObject *)value get];
    if ([value isKindOfClass:NSAppleEventDescriptor.class]) value = [(NSAppleEventDescriptor *)value data];
    if ([value isKindOfClass:NSImage.class]) value = [(NSImage *)value TIFFRepresentation];
    if (![value isKindOfClass:NSData.class] || ![NSImageRep imageRepClassForData:value]) return nil;
    return value;
}

@implementation PlayerReader
+ (int)permissionFor:(NSString *)bundle ask:(BOOL)ask {
    NSAppleEventDescriptor *target = [NSAppleEventDescriptor descriptorWithBundleIdentifier:bundle];
    return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask);
}
+ (SBApplication<MusicPlayer> *)player:(NSString *)bundle {
    if (![NSRunningApplication runningApplicationsWithBundleIdentifier:bundle].count) return nil;
    SBApplication<MusicPlayer> *app = (id)[SBApplication applicationWithBundleIdentifier:bundle];
    app.timeout = 60; // Apple event timeout in ticks.
    return app;
}
+ (NSDictionary *)read:(NSString *)bundle previousArtworkKey:(NSString *)previous {
    @try {
        SBApplication<MusicPlayer> *app = [self player:bundle];
        if (!app) return nil;
        BOOL spotify = [bundle isEqualToString:@"com.spotify.client"];
        SBObject<PlayerTrack> *track = app.currentTrack;
        NSString *name = track.name;
        if (!name.length || app.playerState == 'kPSS') return nil;
        NSString *artist = track.artist ?: @"";
        NSString *album = track.album ?: @"";
        NSString *key = [NSString stringWithFormat:@"%@\n%@\n%@\n%@", bundle, name, artist, album];
        // NSNumber boxes either the Music real or Spotify integer dictionary type.
        double duration = [[track valueForKey:@"duration"] doubleValue] / (spotify ? 1000.0 : 1.0);
        NSMutableDictionary *row = [@{@"name":name, @"artist":artist, @"key":key,
            @"duration":@(duration), @"position":@(app.playerPosition), @"playing":@(app.playerState == 'kPSP')} mutableCopy];
        if (![key isEqual:previous]) {
            if (spotify) {
                NSString *url = track.artworkUrl;
                if (url) row[@"url"] = url;
            } else {
                SBElementArray *art = track.artworks;
                if (art.count) {
                    id<MusicArtwork> artwork = [art objectAtIndex:0];
                    NSData *data = imageData(artwork.rawData) ?: imageData(artwork.data);
                    if (data) row[@"art"] = data;
                }
            }
        }
        return row;
    } @catch (NSException *exception) { return nil; }
}
+ (void)seek:(NSString *)bundle seconds:(double)seconds {
    @try { [[self player:bundle] setPlayerPosition:seconds]; }
    @catch (NSException *exception) {}
}
+ (void)control:(NSString *)bundle command:(NSString *)command {
    @try {
        SBApplication<MusicPlayer> *app = [self player:bundle];
        if ([command isEqual:@"previous"]) [app previousTrack];
        if ([command isEqual:@"toggle"]) [app playpause];
        if ([command isEqual:@"next"]) [app nextTrack];
    } @catch (NSException *exception) {}
}
@end
