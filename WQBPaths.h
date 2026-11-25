//
//  WQBPaths.h
//  WQ Backup
//
//  Backup store layout, manifests and records.
//  GPL-3.0-or-later (derived from WQ Files' backup format ideas).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WQBBackupKind) {
    WQBBackupKindLocal = 0,        // app installed on the device
    WQBBackupKindLiveContainer = 1 // app running inside LiveContainer
};

extern NSString *const WQBBackupManifestName;   // .wqbbackup.plist
extern NSString *const WQBBackupFormatKey;      // Format

NSString *WQBKindName(WQBBackupKind kind);
NSString *WQBKindDisplayName(WQBBackupKind kind);

// YES for a plausible bundle identifier (same rules as WQ Files' app backups).
BOOL WQBIsValidBundleID(NSString *_Nullable bundleID);

// A conservative single path component: only [A-Za-z0-9._-], at most 96 bytes.
// Never empty, never "." or "..".
NSString *WQBSafeName(NSString *_Nullable name);
// A human-readable file name for exports: keeps Unicode letters (Chinese app
// names), removes path separators and control characters.
NSString *WQBFileName(NSString *_Nullable name);

// Deterministic, collision-resistant backup folder key.
NSString *WQBLocalBackupKey(NSString *bundleID);
NSString *WQBGuestBackupKey(NSString *bundleID, NSString *containerFolder);

// Root of this app's backups: Documents/WQBackups. The WQB_BACKUP_ROOT
// environment variable overrides it (host tests).
NSString *WQBBackupRoot(void);
NSString *WQBBackupRootForKind(WQBBackupKind kind);
NSString *WQBBackupKeyFolder(WQBBackupKind kind, NSString *key);

// Documents and Library, in this order.
NSArray<NSString *> *WQBBackupParts(void);

NSString *WQBFormatBytes(unsigned long long bytes);
NSString *WQBBackupStampForDate(NSDate *date);

// Recursively counts regular files and their sizes. Does not follow symbolic
// links. Returns NO when the tree cannot be read completely.
BOOL WQBTreeStats(NSString *path, unsigned long long *_Nullable bytes, NSUInteger *_Nullable files,
                  NSString *_Nullable *_Nullable errorText);

@interface WQBBackupRecord : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) WQBBackupKind kind;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, copy, nullable) NSString *containerFolder;
@property (nonatomic, copy, nullable) NSString *containerLabel;
@property (nonatomic, copy, nullable) NSString *sourceContainer;
@property (nonatomic, copy) NSDate *created;
@property (nonatomic, copy) NSArray<NSString *> *parts;
@property (nonatomic) unsigned long long bytes;
@property (nonatomic) NSUInteger files;
@property (nonatomic) BOOL complete;
@property (nonatomic, copy, nullable) NSString *validationError;

@property (nonatomic, readonly) NSString *dateText;
@property (nonatomic, readonly) NSString *sizeText;
@property (nonatomic, readonly) NSString *detailText;

+ (nullable instancetype)recordAtFolder:(NSString *)folder kind:(WQBBackupKind)kind;
+ (NSArray<WQBBackupRecord *> *)recordsInKeyFolder:(NSString *)folder kind:(WQBBackupKind)kind;
@end

// Writes a manifest atomically into dir. The manifest is only a completion
// marker once Complete is YES.
BOOL WQBWriteManifest(NSString *dir, NSDictionary *manifest, NSString *_Nullable *_Nullable errorText);
NSDictionary *_Nullable WQBReadManifest(NSString *dir);

// Validates a completed backup folder (manifest, parts, hashes shape).
BOOL WQBValidateBackupFolder(NSString *dir, WQBBackupKind *_Nullable kindOut,
                             NSArray<NSString *> *_Nullable *_Nullable partsOut,
                             NSString *_Nullable *_Nullable errorText);

// Recomputes the manifest's per-part file/byte counts and compares them with
// what the backup recorded. Slower than the structural validation only.
BOOL WQBVerifyBackupStats(NSString *dir, NSString *_Nullable *_Nullable errorText);

NS_ASSUME_NONNULL_END
