//
//  WQBBackup.h
//  WQ Backup
//
//  Creates, lists, verifies, exports and restores backups. All heavy work runs
//  on one serial queue; completion blocks are delivered on `notifyQueue`
//  (main by default).
//

#import <Foundation/Foundation.h>
#import "WQBPaths.h"
#import "WQBDiscovery.h"

NS_ASSUME_NONNULL_BEGIN

@interface WQBBackupResult : NSObject
@property (nonatomic) BOOL success;
@property (nonatomic, copy, nullable) NSString *errorText;
@property (nonatomic, strong, nullable) WQBBackupRecord *record;
+ (instancetype)successWithRecord:(WQBBackupRecord *)record;
+ (instancetype)failure:(NSString *)errorText;
@end

@interface WQBBackupEngine : NSObject
+ (instancetype)shared;

@property (nonatomic, readonly) BOOL busy;
// Re-read every copied file and compare it with the manifest's hashes.
// Default YES; the UI exposes it as a setting.
@property (nonatomic) BOOL verifyContents;
@property (nonatomic, strong) dispatch_queue_t notifyQueue;   // main by default

- (void)backupTarget:(WQBAppTarget *)target
            progress:(nullable void (^)(NSString *status))progress
          completion:(void (^)(WQBBackupResult *result))completion;
- (void)restoreBackup:(WQBBackupRecord *)record
                target:(WQBAppTarget *)target
              progress:(nullable void (^)(NSString *status))progress
            completion:(void (^)(WQBBackupResult *result))completion;
- (void)verifyBackup:(WQBBackupRecord *)record
            progress:(nullable void (^)(NSString *status))progress
          completion:(void (^)(WQBBackupResult *result))completion;
- (void)deleteBackup:(WQBBackupRecord *)record
          completion:(void (^)(BOOL ok, NSString *_Nullable errorText))completion;
- (void)exportZIPForBackup:(WQBBackupRecord *)record
                  progress:(nullable void (^)(NSString *status))progress
                completion:(void (^)(NSString *_Nullable zipPath, NSString *_Nullable errorText))completion;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
