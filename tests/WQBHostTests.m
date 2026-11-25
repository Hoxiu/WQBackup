//
//  WQBHostTests.m
//  WQ Backup host fixtures (macOS). No device or container access is used.
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <errno.h>
#import <sys/stat.h>
#import "WQBPaths.h"
#import "WQBDiscovery.h"
#import "WQBBackup.h"
#import "WQArchive.h"
#import "WQAccess.h"

// WQAccess asks the Security framework for the app's group; the host test has
// none, and the private symbol isn't linkable off-device.
SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) { (void)allocator; return NULL; }
CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error)
{ (void)task; (void)entitlement; (void)error; return NULL; }

static NSUInteger gChecks;

static void check(BOOL condition, NSString *what)
{
    gChecks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", what.UTF8String);
        exit(1);
    }
}

static void writeFile(NSString *path, NSData *data)
{
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    check([data writeToFile:path atomically:YES], [@"write " stringByAppendingString:path.lastPathComponent]);
}

static void writeText(NSString *path, NSString *text)
{
    writeFile(path, [text dataUsingEncoding:NSUTF8StringEncoding]);
}

static NSString *readText(NSString *path)
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static WQBAppTarget *localTarget(NSString *container, NSString *bundleID)
{
    WQBAppTarget *target = [WQBAppTarget new];
    target.kind = WQBBackupKindLocal;
    target.name = @"Demo App";
    target.bundleID = bundleID;
    target.key = WQBLocalBackupKey(bundleID);
    target.containerPath = container;
    target.available = YES;
    return target;
}

static WQBBackupResult *runBackup(WQBAppTarget *target, BOOL verify)
{
    WQBBackupEngine *engine = WQBBackupEngine.shared;
    engine.verifyContents = verify;
    engine.notifyQueue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block WQBBackupResult *outcome = nil;
    [engine backupTarget:target progress:nil completion:^(WQBBackupResult *result) {
        outcome = result;
        dispatch_semaphore_signal(done);
    }];
    check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) == 0, @"backup finished");
    return outcome;
}

static WQBBackupResult *runRestore(WQBBackupRecord *record, WQBAppTarget *target)
{
    WQBBackupEngine *engine = WQBBackupEngine.shared;
    engine.notifyQueue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block WQBBackupResult *outcome = nil;
    [engine restoreBackup:record target:target progress:nil completion:^(WQBBackupResult *result) {
        outcome = result;
        dispatch_semaphore_signal(done);
    }];
    check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) == 0, @"restore finished");
    return outcome;
}

static WQBBackupResult *runVerify(WQBBackupRecord *record)
{
    WQBBackupEngine *engine = WQBBackupEngine.shared;
    engine.notifyQueue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block WQBBackupResult *outcome = nil;
    [engine verifyBackup:record progress:nil completion:^(WQBBackupResult *result) {
        outcome = result;
        dispatch_semaphore_signal(done);
    }];
    check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) == 0, @"verify finished");
    return outcome;
}

int main(void)
{
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [@"WQBHostTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [fm createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("WQB_BACKUP_ROOT", [base stringByAppendingPathComponent:@"Store"].fileSystemRepresentation, 1);

        check(WQBIsValidBundleID(@"com.example.demo"), @"bundle id accepted");
        check(!WQBIsValidBundleID(@"not a bundle"), @"invalid bundle id rejected");
        check([WQBSafeName(@".hidden") isEqualToString:@"x.hidden"], @"safe name keeps hidden folders visible");
        check(WQBGuestBackupKey(@"com.example.demo", @"ABC").length > 10, @"guest key is stable");
        check(WQBAppOriginForBundle(@"com.example.demo",
              @"/private/var/containers/Bundle/Application/ABC/Demo.app") == WQBAppOriginUser,
              @"bundle container is a user app");
        check(WQBAppOriginForBundle(@"com.apple.Safari", @"/Applications/MobileSafari.app") == WQBAppOriginSystem,
              @"/Applications is a system app");
        check(WQBAppOriginForBundle(@"com.apple.Maps",
              @"/private/var/staged_system_apps/Maps.app") == WQBAppOriginSystem,
              @"staged system app is a system app");
        check(WQBAppOriginForBundle(@"com.apple.Safari", nil) == WQBAppOriginSystem,
              @"com.apple fallback is system");
        check(WQBAppOriginForBundle(@"com.example.unknown", nil) == WQBAppOriginUser,
              @"unknown non-Apple fallback is user");

        // --- Local app backup / restore / verify / export -------------------
        NSString *localContainer = [base stringByAppendingPathComponent:@"Data/Application/11111111"];
        writeText([localContainer stringByAppendingPathComponent:@"Documents/note.txt"], @"hello");
        writeFile([localContainer stringByAppendingPathComponent:@"Documents/sub/data.bin"],
                  [NSMutableData dataWithLength:4096]);
        writeText([localContainer stringByAppendingPathComponent:@"Library/Preferences/prefs.plist"], @"prefs");
        writeText([localContainer stringByAppendingPathComponent:@"Library/Caches/cache.bin"], @"cache");
        WQBAppTarget *local = localTarget(localContainer, @"com.example.demo");
        WQBBackupResult *backedUp = runBackup(local, YES);
        check(backedUp.success, backedUp.errorText ?: @"local backup succeeded");
        check(backedUp.record.complete, @"record is complete");
        check(backedUp.record.parts.count == 2, @"both parts recorded");
        check(backedUp.record.files == 4, @"four files recorded");
        check(backedUp.record.bytes == 4096 + 5 + 5 + 5, @"byte total recorded");
        NSString *recordPath = backedUp.record.path;
        check([fm fileExistsAtPath:[recordPath stringByAppendingPathComponent:@"Documents/note.txt"]], @"backup has Documents");
        check([fm fileExistsAtPath:[recordPath stringByAppendingPathComponent:WQBBackupManifestName]], @"backup has manifest");
        NSDictionary *manifest = WQBReadManifest(recordPath);
        check([manifest[@"BundleID"] isEqualToString:@"com.example.demo"], @"manifest bundle id");
        check([manifest[@"Kind"] isEqualToString:@"Local"], @"manifest kind");
        check(manifest[@"PartHashes"] != nil, @"manifest content hashes");

        check(runVerify(backedUp.record).success, @"verify succeeds");
        check(WQBVerifyBackupStats(recordPath, NULL), @"stats match");

        // Change the live data, restore, check the backup wins and extra files survive.
        writeText([localContainer stringByAppendingPathComponent:@"Documents/note.txt"], @"changed");
        writeText([localContainer stringByAppendingPathComponent:@"Library/extra.txt"], @"extra");
        WQBBackupResult *restored = runRestore(backedUp.record, local);
        check(restored.success, restored.errorText ?: @"restore succeeded");
        check([readText([localContainer stringByAppendingPathComponent:@"Documents/note.txt"]) isEqualToString:@"hello"],
              @"restore brings back original content");
        check([fm fileExistsAtPath:[localContainer stringByAppendingPathComponent:@"Library/extra.txt"]],
              @"restore keeps files not in the backup");
        check([readText([localContainer stringByAppendingPathComponent:@"Library/Preferences/prefs.plist"]) isEqualToString:@"prefs"],
              @"restore brings back Library");

        // Export as ZIP, extract, compare.
        dispatch_semaphore_t zipDone = dispatch_semaphore_create(0);
        __block NSString *zipPath = nil;
        __block NSString *zipError = nil;
        WQBBackupEngine.shared.notifyQueue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        [WQBBackupEngine.shared exportZIPForBackup:backedUp.record progress:nil completion:^(NSString *path, NSString *error) {
            zipPath = path;
            zipError = error;
            dispatch_semaphore_signal(zipDone);
        }];
        check(dispatch_semaphore_wait(zipDone, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) == 0, @"zip export finished");
        check(zipPath.length > 0, zipError ?: @"zip export succeeded");
        NSString *extractDir = [base stringByAppendingPathComponent:@"extract"];
        [fm createDirectoryAtPath:extractDir withIntermediateDirectories:YES attributes:nil error:nil];
        check(wq_zip_extract(zipPath, extractDir, wq_archive_posix_io(), 100 * 1024 * 1024, nil, nil, NULL, NULL, NULL),
              @"zip extracts");
        check([readText([extractDir stringByAppendingPathComponent:@"Documents/note.txt"]) isEqualToString:@"hello"],
              @"zip contains Documents");

        // Cleanup.
        dispatch_semaphore_t deleteDone = dispatch_semaphore_create(0);
        __block BOOL deleted = NO;
        [WQBBackupEngine.shared deleteBackup:backedUp.record completion:^(BOOL ok, NSString *error) {
            deleted = ok;
            if (!ok) fprintf(stderr, "delete: %s\n", (error ?: @"?").UTF8String);
            dispatch_semaphore_signal(deleteDone);
        }];
        check(dispatch_semaphore_wait(deleteDone, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0, @"delete finished");
        check(deleted && ![fm fileExistsAtPath:recordPath], @"backup deleted");

        // --- LiveContainer discovery ---------------------------------------
        NSString *lcContainer = [base stringByAppendingPathComponent:@"LiveContainer"];
        NSString *appsDir = [lcContainer stringByAppendingPathComponent:@"Documents/Applications"];
        NSString *guest = [appsDir stringByAppendingPathComponent:@"com.example.guest.app"];
        writeFile([guest stringByAppendingPathComponent:@"Info.plist"],
                  [NSPropertyListSerialization dataWithPropertyList:@{
                      @"CFBundleIdentifier": @"com.example.guest",
                      @"CFBundleDisplayName": @"Guest App",
                      @"CFBundleExecutable": @"Guest"
                  } format:NSPropertyListXMLFormat_v1_0 options:0 error:nil]);
        writeFile([guest stringByAppendingPathComponent:@"LCAppInfo.plist"],
                  [NSPropertyListSerialization dataWithPropertyList:@{
                      @"LCDataUUID": @"DEF",
                      @"LCContainers": @[
                          @{@"folderName": @"DEF", @"name": @"工作"},
                          @{@"folderName": @"ABC", @"name": @"默认"}
                      ]
                  } format:NSPropertyListXMLFormat_v1_0 options:0 error:nil]);
        writeText([lcContainer stringByAppendingPathComponent:@"Documents/Data/Application/DEF/Documents/d.txt"], @"d");
        writeText([lcContainer stringByAppendingPathComponent:@"Documents/Data/Application/DEF/Library/l.txt"], @"l");
        writeText([lcContainer stringByAppendingPathComponent:@"Documents/Data/Application/ABC/Documents/a.txt"], @"a");

        NSString *legacy = [appsDir stringByAppendingPathComponent:@"com.example.legacy.app"];
        writeFile([legacy stringByAppendingPathComponent:@"Info.plist"],
                  [NSPropertyListSerialization dataWithPropertyList:@{
                      @"CFBundleIdentifier": @"com.example.legacy",
                      @"CFBundleDisplayName": @"Legacy App"
                  } format:NSPropertyListXMLFormat_v1_0 options:0 error:nil]);
        writeText([legacy stringByAppendingPathComponent:@"Data/Documents/old.txt"], @"old");

        NSArray<WQBLiveContainerRoot *> *roots = WQBLiveContainerRootsInContainer(lcContainer);
        check(roots.count == 1, @"one LiveContainer root found");
        check([roots[0].path hasSuffix:@"LiveContainer/Documents"], @"root is Documents");
        NSArray<WQBAppTarget *> *guests = WQBGuestTargetsInRoot(roots[0], roots);
        check(guests.count == 3, @"guest has two containers plus legacy data");
        NSUInteger defCount = 0, legacyCount = 0;
        for (WQBAppTarget *target in guests) {
            check([target.bundleID hasPrefix:@"com.example"], @"guest bundle id");
            check(target.kind == WQBBackupKindLiveContainer, @"guest kind");
            check(target.origin == WQBAppOriginUser, @"guest origin is user");
            if (![target.lcContainerLabel isEqualToString:@"旧版数据"])
                check([target.containerPath containsString:@"Data/Application/"], @"guest data path");
            if ([target.lcContainerLabel isEqualToString:@"工作"]) {
                defCount++;
                check(target.available, @"guest container available");
                check([target.key containsString:@"DEF"], @"guest key uses container folder");
            }
            if ([target.lcContainerLabel isEqualToString:@"旧版数据"]) legacyCount++;
        }
        check(defCount == 1, @"named container found");
        check(legacyCount == 1, @"legacy data found");

        // A guest backup goes to the LiveContainer store, not the local store.
        WQBAppTarget *guestTarget = nil;
        for (WQBAppTarget *target in guests)
            if ([target.lcContainerLabel isEqualToString:@"工作"]) guestTarget = target;
        WQBBackupResult *guestBackup = runBackup(guestTarget, NO);
        check(guestBackup.success, guestBackup.errorText ?: @"guest backup succeeded");
        check([guestBackup.record.path hasPrefix:WQBBackupRootForKind(WQBBackupKindLiveContainer)],
              @"guest backup stored separately");
        check([guestBackup.record.containerFolder isEqualToString:@"DEF"], @"guest manifest folder");

        // --- LiveContainer App Group (shared containers) ---------------------
        NSString *group = [base stringByAppendingPathComponent:@"Shared/AppGroup/GROUPUUID"];
        NSString *groupLC = [group stringByAppendingPathComponent:@"LiveContainer"];
        NSString *sharedGuest = [groupLC stringByAppendingPathComponent:@"Applications/com.example.shared.app"];
        writeFile([sharedGuest stringByAppendingPathComponent:@"Info.plist"],
                  [NSPropertyListSerialization dataWithPropertyList:@{
                      @"CFBundleIdentifier": @"com.example.shared",
                      @"CFBundleDisplayName": @"Shared App"
                  } format:NSPropertyListXMLFormat_v1_0 options:0 error:nil]);
        writeFile([sharedGuest stringByAppendingPathComponent:@"LCAppInfo.plist"],
                  [NSPropertyListSerialization dataWithPropertyList:@{
                      @"LCDataUUID": @"SHARED",
                      @"LCContainers": @[ @{@"folderName": @"SHARED", @"name": @"共享", @"isShared": @YES} ]
                  } format:NSPropertyListXMLFormat_v1_0 options:0 error:nil]);
        writeText([groupLC stringByAppendingPathComponent:@"Data/Application/SHARED/Documents/s.txt"], @"shared");
        NSArray<WQBLiveContainerRoot *> *groupRoots = WQBLiveContainerRootsInGroupContainer(group);
        check(groupRoots.count == 1 && groupRoots[0].isAppGroup, @"app-group LiveContainer root found");
        NSArray<WQBLiveContainerRoot *> *allRoots = [roots arrayByAddingObjectsFromArray:groupRoots];
        NSArray<WQBAppTarget *> *sharedTargets = WQBGuestTargetsInRoot(groupRoots[0], allRoots);
        check(sharedTargets.count == 1, @"shared guest listed");
        check([sharedTargets[0].containerPath hasSuffix:@"LiveContainer/Data/Application/SHARED"],
              @"shared guest data stays in the App Group");

        // --- Local discovery through the container label --------------------
        NSString *localContainer2 = [base stringByAppendingPathComponent:@"Data/Application/22222222"];
        writeText([localContainer2 stringByAppendingPathComponent:@"Documents/x.txt"], @"x");
        writeFile([localContainer2 stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"],
                  [NSPropertyListSerialization dataWithPropertyList:@{
                      @"MCMMetadataIdentifier": @"com.example.local"
                  } format:NSPropertyListXMLFormat_v1_0 options:0 error:nil]);
        NSArray<WQBAppTarget *> *locals = WQBLocalTargetsFromContainers(@[localContainer2], nil);
        check(locals.count == 1, @"local container listed");
        check([locals[0].bundleID isEqualToString:@"com.example.local"], @"local bundle id from metadata");
        check(locals[0].origin == WQBAppOriginUser, @"local demo app classified as user");

        // A system app container without a bundle path is classified from its
        // com.apple bundle id.
        NSString *systemContainer = [base stringByAppendingPathComponent:@"Data/Application/33333333"];
        writeText([systemContainer stringByAppendingPathComponent:@"Documents/system.txt"], @"s");
        writeFile([systemContainer stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"],
                  [NSPropertyListSerialization dataWithPropertyList:@{
                      @"MCMMetadataIdentifier": @"com.apple.Safari"
                  } format:NSPropertyListXMLFormat_v1_0 options:0 error:nil]);
        NSArray<WQBAppTarget *> *systemApps = WQBLocalTargetsFromContainers(@[systemContainer], nil);
        check(systemApps.count == 1 && systemApps[0].origin == WQBAppOriginSystem,
              @"system app classified as system");

        // Incomplete backup is refused.
        NSString *broken = [base stringByAppendingPathComponent:@"Store/Local/broken/2026-01-01 00.00.00"];
        writeText([broken stringByAppendingPathComponent:@"Documents/x"], @"x");
        check(!WQBValidateBackupFolder(broken, NULL, NULL, NULL), @"incomplete backup rejected");
        check([WQBBackupRecord recordAtFolder:broken kind:WQBBackupKindLocal] != nil, @"incomplete backup still shown");
        check(![WQBBackupRecord recordAtFolder:broken kind:WQBBackupKindLocal].complete, @"incomplete record marked");

        printf("PASS: %lu checks\n", (unsigned long)gChecks);
        [fm removeItemAtPath:base error:nil];
        printf("PASS: WQBHostTests\n");
    }
    return 0;
}
