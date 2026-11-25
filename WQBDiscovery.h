//
//  WQBDiscovery.h
//  WQ Backup
//
//  Finds installed apps and LiveContainer guest apps through the same
//  worse_query access layer WQ Files uses.
//

#import <Foundation/Foundation.h>
#import "WQBPaths.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WQBAppOrigin) {
    WQBAppOriginUnknown = 0,
    WQBAppOriginUser,     // App Store, AltStore, SideStore, TestFlight, enterprise…
    WQBAppOriginSystem    // bundled with iOS
};

NSString *WQBOriginText(WQBAppOrigin origin);

// Classifies an installed app by the bundle path the LaunchServices database
// reports: user apps live in Containers/Bundle/Application, system apps in
// /Applications or staged_system_apps. Falls back to com.apple.* when the
// database has no path.
WQBAppOrigin WQBAppOriginForBundle(NSString *_Nullable bundleID, NSString *_Nullable bundlePath);

// One backupable data container. For a locally installed app this is
// /private/var/mobile/Containers/Data/Application/<UUID>; for a LiveContainer
// guest it is the guest's data folder (Documents/Data/Application/<folder>).
@interface WQBAppTarget : NSObject
@property (nonatomic) WQBBackupKind kind;
@property (nonatomic, copy) NSString *name;              // display name
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *key;               // backup folder key
@property (nonatomic, copy) NSString *containerPath;     // data folder to back up
@property (nonatomic) WQBAppOrigin origin;
@property (nonatomic, copy, nullable) NSString *bundlePath; // .app path, for icons
@property (nonatomic) BOOL available;
@property (nonatomic, copy, nullable) NSString *note;    // why unavailable / extra info
// LiveContainer-only:
@property (nonatomic, copy, nullable) NSString *lcRootPath;
@property (nonatomic, copy, nullable) NSString *lcAppFolder;
@property (nonatomic, copy, nullable) NSString *lcContainerFolder;
@property (nonatomic, copy, nullable) NSString *lcContainerLabel;
@property (nonatomic, copy, nullable) NSString *lcOwnerName;
@property (nonatomic, copy) NSArray<WQBBackupRecord *> *backups;

@property (nonatomic, readonly) NSString *subtitleText;
@property (nonatomic, readonly) NSString *backupSummaryText;
- (void)reloadBackups;
@end

// A LiveContainer storage root: either <LiveContainer container>/Documents or
// <App Group>/LiveContainer. Applications and Data/Application live below it.
@interface WQBLiveContainerRoot : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *grantRoot;   // container to obtain a token for
@property (nonatomic) BOOL isAppGroup;
@property (nonatomic, copy) NSString *ownerID;
@property (nonatomic, copy) NSString *ownerName;
@end

@interface WQBDiscovery : NSObject

// Both are blocking; call from a background queue. `progress` is called from
// that queue with a human-readable status. On failure the array is empty and
// `note` explains why.
+ (NSArray<WQBAppTarget *> *)discoverLocalAppsWithProgress:(nullable void (^)(NSString *status))progress
                                                      note:(NSString *_Nullable *_Nullable)note;
+ (NSArray<WQBAppTarget *> *)discoverLiveContainerAppsWithProgress:(nullable void (^)(NSString *status))progress
                                                               note:(NSString *_Nullable *_Nullable)note;

// Forget cached discovery results; the next call scans again.
+ (void)invalidateCache;

// Filesystem-level helpers, also used by the host tests.
NSArray<WQBLiveContainerRoot *> *WQBLiveContainerRootsInContainer(NSString *containerPath);
NSArray<WQBLiveContainerRoot *> *WQBLiveContainerRootsInGroupContainer(NSString *groupPath);
NSArray<WQBAppTarget *> *WQBGuestTargetsInRoot(WQBLiveContainerRoot *root,
                                                NSArray<WQBLiveContainerRoot *> *allRoots);
NSArray<WQBAppTarget *> *WQBLocalTargetsFromContainers(NSArray<NSString *> *containers,
                                                        NSString *_Nullable ownHome);

@end

NS_ASSUME_NONNULL_END
