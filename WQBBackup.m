//
//  WQBBackup.m
//  WQ Backup
//

#import "WQBBackup.h"
#import "WQAccess.h"
#import "WQAppsSupport.h"
#import "WQArchive.h"
#import <errno.h>
#import <sys/stat.h>

static const unsigned long long kWQBMinimumFreeSpace = 64ULL * 1024 * 1024;
static const unsigned long long kWQBMaxZipBytes = 3900ULL * 1024 * 1024;

// A LiveContainer guest's data folder is nested several levels below the
// container that can be granted. Try the folder first, then its parents.
static void WQBGrantPath(NSString *path)
{
    NSString *candidate = path.stringByStandardizingPath;
    for (NSUInteger depth = 0; depth < 8 && candidate.length > 1; depth++) {
        if (wq_grant(candidate)) return;
        candidate = candidate.stringByDeletingLastPathComponent;
    }
}

@implementation WQBBackupResult

+ (instancetype)successWithRecord:(WQBBackupRecord *)record
{
    WQBBackupResult *result = [WQBBackupResult new];
    result.success = YES;
    result.record = record;
    return result;
}

+ (instancetype)failure:(NSString *)errorText
{
    WQBBackupResult *result = [WQBBackupResult new];
    result.success = NO;
    result.errorText = errorText ?: @"未知错误";
    return result;
}

@end

@implementation WQBBackupEngine {
    dispatch_queue_t _queue;
    NSLock *_stateLock;
    BOOL _busy;
    BOOL _cancelled;
}

@synthesize notifyQueue = _notifyQueue;

+ (instancetype)shared
{
    static WQBBackupEngine *engine;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        engine = [WQBBackupEngine new];
    });
    return engine;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.wqbackup.engine", DISPATCH_QUEUE_SERIAL);
        _stateLock = [NSLock new];
        _verifyContents = YES;
    }
    return self;
}

- (dispatch_queue_t)notifyQueue
{
    @synchronized (self) {
        return _notifyQueue ?: dispatch_get_main_queue();
    }
}

- (BOOL)busy
{
    [_stateLock lock];
    BOOL busy = _busy;
    [_stateLock unlock];
    return busy;
}

- (BOOL)beginOperation
{
    [_stateLock lock];
    BOOL started = !_busy;
    if (started) {
        _busy = YES;
        _cancelled = NO;
    }
    [_stateLock unlock];
    return started;
}

- (void)finishOperation
{
    [_stateLock lock];
    _busy = NO;
    _cancelled = NO;
    [_stateLock unlock];
}

- (void)cancel
{
    [_stateLock lock];
    _cancelled = YES;
    [_stateLock unlock];
}

- (BOOL)cancelledNow
{
    [_stateLock lock];
    BOOL cancelled = _cancelled;
    [_stateLock unlock];
    return cancelled;
}

- (void)deliver:(dispatch_block_t)block
{
    dispatch_async(self.notifyQueue, block);
}

- (void)runOperation:(WQBBackupResult * (^)(void (^progress)(NSString *)))operation
            progress:(void (^)(NSString *))progress
          completion:(void (^)(WQBBackupResult *))completion
{
    if (![self beginOperation]) {
        [self deliver:^{ completion([WQBBackupResult failure:@"已有任务正在进行，请稍候"]); }];
        return;
    }
    dispatch_async(_queue, ^{
        WQBBackupResult *result = operation(^(NSString *status) {
            if (progress) [self deliver:^{ progress(status); }];
        });
        [self finishOperation];
        [self deliver:^{ completion(result); }];
    });
}

#pragma mark - Backup

- (void)backupTarget:(WQBAppTarget *)target
            progress:(void (^)(NSString *))progress
          completion:(void (^)(WQBBackupResult *))completion
{
    [self runOperation:^WQBBackupResult *(void (^report)(NSString *)) {
        return [self backupTargetNow:target report:report];
    } progress:progress completion:completion];
}

- (WQBBackupResult *)backupTargetNow:(WQBAppTarget *)target report:(void (^)(NSString *))report
{
    if (!target.available) return [WQBBackupResult failure:target.note ?: @"这个应用当前不可备份"];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *container = target.containerPath.stringByStandardizingPath;
    WQBGrantPath(container);
    if (![fm fileExistsAtPath:container]) return [WQBBackupResult failure:@"应用的数据文件夹已不存在"];

    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    for (NSString *part in WQBBackupParts()) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:[container stringByAppendingPathComponent:part] isDirectory:&isDir] && isDir)
            [parts addObject:part];
    }
    if (!parts.count) return [WQBBackupResult failure:@"这个应用的 Documents 与 Library 都不存在，没有可备份的数据"];

    NSString *keyDir = WQBBackupKeyFolder(target.kind, target.key);
    if (![fm createDirectoryAtPath:keyDir withIntermediateDirectories:YES attributes:nil error:nil])
        return [WQBBackupResult failure:@"无法创建备份文件夹（存储空间或权限问题）"];
    NSDictionary *fsAttributes = [fm attributesOfFileSystemForPath:keyDir error:nil];
    unsigned long long freeSpace = [fsAttributes[NSFileSystemFreeSize] unsignedLongLongValue];
    if (freeSpace && freeSpace < kWQBMinimumFreeSpace)
        return [WQBBackupResult failure:@"可用存储空间不足 64 MB，无法开始备份"];
    for (NSString *name in [fm contentsOfDirectoryAtPath:keyDir error:nil])
        if ([name hasPrefix:@".staging-"]) [fm removeItemAtPath:[keyDir stringByAppendingPathComponent:name] error:nil];

    NSDate *created = NSDate.date;
    NSString *staging = [keyDir stringByAppendingPathComponent:
                         [@".staging-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![fm createDirectoryAtPath:staging withIntermediateDirectories:NO attributes:nil error:nil])
        return [WQBBackupResult failure:@"无法创建备份暂存文件夹"];

    NSMutableDictionary<NSString *, NSDictionary *> *partStats = [NSMutableDictionary new];
    NSMutableDictionary<NSString *, NSString *> *partHashes = [NSMutableDictionary new];
    unsigned long long totalBytes = 0;
    NSUInteger totalFiles = 0;
    NSString *error = nil;
    BOOL verify = self.verifyContents;
    for (NSString *part in parts) {
        if ([self cancelledNow]) { error = @"已取消"; break; }
        NSString *src = [container stringByAppendingPathComponent:part];
        NSString *dst = [staging stringByAppendingPathComponent:part];
        report([NSString stringWithFormat:@"正在备份 %@…", part]);
        BOOL sourceExists = NO;
        NSString *before = WQAppsSupportTreeSignature(src, YES, &sourceExists, &error);
        if (!before || !sourceExists) {
            error = error ?: [NSString stringWithFormat:@"无法读取 %@", part];
            break;
        }
        if (!wq_copy_tree_new(src, dst, ^BOOL { return [self cancelledNow]; }, &error)) break;
        if ([self cancelledNow]) { error = @"已取消"; break; }

        BOOL afterExists = NO;
        NSString *after = WQAppsSupportTreeSignature(src, YES, &afterExists, &error);
        NSUInteger omitted = 0;
        NSString *sourceShape = WQAppsSupportTreeSignatureOmitting(src, NO, NULL, &omitted, &error);
        BOOL copiedExists = NO;
        NSString *copiedShape = WQAppsSupportTreeSignature(dst, NO, &copiedExists, &error);
        if (!after || !sourceShape || !copiedShape || !afterExists || !copiedExists) {
            error = error ?: @"无法校验复制结果";
            break;
        }
        if (![before isEqualToString:after]) {
            error = [NSString stringWithFormat:@"备份时 %@ 发生了变化（应用可能正在运行），请关闭应用后重试", part];
            break;
        }
        if (![sourceShape isEqualToString:copiedShape]) {
            error = [NSString stringWithFormat:@"%@ 的复制结果不完整", part];
            break;
        }
        if (verify) {
            NSString *sourceHash = WQAppsSupportTreeContentSignature(src, NULL, &error);
            NSString *copiedHash = WQAppsSupportTreeContentSignature(dst, NULL, &error);
            if (!sourceHash || !copiedHash || ![sourceHash isEqualToString:copiedHash]) {
                error = error ?: [NSString stringWithFormat:@"%@ 的文件内容校验失败", part];
                break;
            }
            partHashes[part] = copiedHash;
        }
        unsigned long long bytes = 0;
        NSUInteger files = 0;
        if (!WQBTreeStats(dst, &bytes, &files, &error)) break;
        partStats[part] = @{ @"Files": @(files), @"Bytes": @(bytes) };
        totalBytes += bytes;
        totalFiles += files;
    }

    if ([self cancelledNow]) {
        [fm removeItemAtPath:staging error:nil];
        wq_log(@"backup %@: cancelled", target.bundleID);
        return [WQBBackupResult failure:@"已取消"];
    }
    if (error) {
        [fm removeItemAtPath:staging error:nil];
        wq_log(@"backup %@: FAILED (%@)", target.bundleID, error);
        return [WQBBackupResult failure:error];
    }

    NSMutableDictionary *manifest = [@{
        @"Format": @1,
        @"Complete": @YES,
        @"Kind": WQBKindName(target.kind),
        @"Key": target.key,
        @"BundleID": target.bundleID,
        @"AppName": target.name,
        @"Created": created,
        @"SourceContainer": container,
        @"Parts": parts,
        @"PartStats": partStats,
        @"Files": @(totalFiles),
        @"Bytes": @(totalBytes),
        @"Verified": @(verify)
    } mutableCopy];
    if (partHashes.count) manifest[@"PartHashes"] = partHashes;
    if (target.kind == WQBBackupKindLiveContainer) {
        if (target.lcContainerFolder.length) manifest[@"ContainerFolder"] = target.lcContainerFolder;
        if (target.lcContainerLabel.length) manifest[@"ContainerLabel"] = target.lcContainerLabel;
        if (target.lcAppFolder.length) manifest[@"AppFolder"] = target.lcAppFolder;
        if (target.lcRootPath.length) manifest[@"LiveContainerRoot"] = target.lcRootPath;
    }
    struct stat containerStat;
    if (lstat(container.fileSystemRepresentation, &containerStat) == 0) {
        manifest[@"SourceDevice"] = @((unsigned long long)containerStat.st_dev);
        manifest[@"SourceInode"] = @((unsigned long long)containerStat.st_ino);
    }

    report(@"正在写入备份信息…");
    if (!WQBWriteManifest(staging, manifest, &error)) {
        [fm removeItemAtPath:staging error:nil];
        return [WQBBackupResult failure:error ?: @"无法写入备份信息"];
    }
    WQBBackupKind validatedKind = target.kind;
    if (!WQBValidateBackupFolder(staging, &validatedKind, NULL, &error)) {
        [fm removeItemAtPath:staging error:nil];
        return [WQBBackupResult failure:error ?: @"备份校验失败"];
    }

    NSString *stamp = WQBBackupStampForDate(created);
    NSString *final = [keyDir stringByAppendingPathComponent:stamp];
    NSUInteger sequence = 1;
    while ([fm fileExistsAtPath:final]) {
        sequence++;
        final = [keyDir stringByAppendingPathComponent:
                 [NSString stringWithFormat:@"%@ (%lu)", stamp, (unsigned long)sequence]];
    }
    manifest[@"Sequence"] = @(sequence);
    if (!WQBWriteManifest(staging, manifest, &error)) {
        [fm removeItemAtPath:staging error:nil];
        return [WQBBackupResult failure:error ?: @"无法写入备份信息"];
    }
    NSError *moveError = nil;
    if (![fm moveItemAtPath:staging toPath:final error:&moveError]) {
        [fm removeItemAtPath:staging error:nil];
        return [WQBBackupResult failure:moveError.localizedDescription ?: @"无法保存备份"];
    }
    WQBBackupRecord *record = [WQBBackupRecord recordAtFolder:final kind:target.kind];
    if (!record || !record.complete) {
        [fm removeItemAtPath:final error:nil];
        return [WQBBackupResult failure:record.validationError ?: @"备份完成后校验失败"];
    }
    report(@"完成");
    wq_log(@"backup %@ -> %@ (%@, %@)", target.bundleID, final.lastPathComponent,
           record.sizeText, [parts componentsJoinedByString:@"+"]);
    return [WQBBackupResult successWithRecord:record];
}

#pragma mark - Restore

- (void)restoreBackup:(WQBBackupRecord *)record
                target:(WQBAppTarget *)target
              progress:(void (^)(NSString *))progress
            completion:(void (^)(WQBBackupResult *))completion
{
    [self runOperation:^WQBBackupResult *(void (^report)(NSString *)) {
        return [self restoreNow:record target:target report:report];
    } progress:progress completion:completion];
}

- (WQBBackupResult *)restoreNow:(WQBBackupRecord *)record target:(WQBAppTarget *)target
                         report:(void (^)(NSString *))report
{
    if (target.kind == WQBBackupKindLiveContainer && !target.available &&
        [target.containerPath isEqualToString:(target.lcAppFolder ?: @"")])
        return [WQBBackupResult failure:target.note ?: @"目标应用还没有数据容器，无法恢复"];
    if (![target.bundleID isEqualToString:record.bundleID])
        return [WQBBackupResult failure:@"这个备份属于另一个应用，不能恢复到这里"];
    if (target.kind != record.kind) return [WQBBackupResult failure:@"备份类型不匹配"];
    if (target.kind == WQBBackupKindLiveContainer &&
        record.containerFolder.length && target.lcContainerFolder.length &&
        ![record.containerFolder isEqualToString:target.lcContainerFolder])
        return [WQBBackupResult failure:@"这个备份属于 LiveContainer 的另一个数据容器"];
    WQBBackupKind kind = record.kind;
    NSArray *parts = nil;
    NSString *error = nil;
    if (!WQBValidateBackupFolder(record.path, &kind, &parts, &error))
        return [WQBBackupResult failure:error ?: @"备份无效"];
    if (!WQBVerifyBackupStats(record.path, &error))
        return [WQBBackupResult failure:error ?: @"备份文件数量与备份时不一致"];

    NSString *container = target.containerPath.stringByStandardizingPath;
    WQBGrantPath(container);
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:container]) return [WQBBackupResult failure:@"目标应用的数据文件夹已不存在"];
    if (target.kind == WQBBackupKindLocal) {
        NSString *label = wq_container_label(container);
        if (label.length && ![label isEqualToString:target.bundleID])
            return [WQBBackupResult failure:@"目标容器已被替换，请重新扫描应用列表"];
    }
    for (NSString *part in parts) {
        if ([self cancelledNow]) return [WQBBackupResult failure:@"已取消（已恢复的部分保留）"];
        NSString *src = [record.path stringByAppendingPathComponent:part];
        NSString *dst = [container stringByAppendingPathComponent:part];
        report([NSString stringWithFormat:@"正在恢复 %@…", part]);
        if (!wq_copy_contents(src, dst, &error))
            return [WQBBackupResult failure:[NSString stringWithFormat:
                @"恢复 %@ 失败：%@（已恢复的文件保留，请重新打开应用检查）", part, error ?: @"未知错误"]];
    }
    report(@"完成");
    wq_log(@"restore %@ <- %@", target.bundleID, record.name);
    return [WQBBackupResult successWithRecord:record];
}

#pragma mark - Verify

- (void)verifyBackup:(WQBBackupRecord *)record
            progress:(void (^)(NSString *))progress
          completion:(void (^)(WQBBackupResult *))completion
{
    [self runOperation:^WQBBackupResult *(void (^report)(NSString *)) {
        WQBBackupKind kind = record.kind;
        NSArray *parts = nil;
        NSString *error = nil;
        report(@"正在检查备份…");
        if (!WQBValidateBackupFolder(record.path, &kind, &parts, &error))
            return [WQBBackupResult failure:error ?: @"备份无效"];
        if (!WQBVerifyBackupStats(record.path, &error))
            return [WQBBackupResult failure:error ?: @"备份文件数量与备份时不一致"];
        NSDictionary *hashes = WQBReadManifest(record.path)[@"PartHashes"];
        if ([hashes isKindOfClass:NSDictionary.class]) {
            for (NSString *part in parts) {
                if ([self cancelledNow]) return [WQBBackupResult failure:@"已取消"];
                NSString *expected = hashes[part];
                if (![expected isKindOfClass:NSString.class] || !expected.length) continue;
                report([NSString stringWithFormat:@"正在校验 %@ 的内容…", part]);
                NSString *actual = WQAppsSupportTreeContentSignature(
                    [record.path stringByAppendingPathComponent:part], NULL, &error);
                if (!actual || ![actual isEqualToString:expected])
                    return [WQBBackupResult failure:[NSString stringWithFormat:@"%@ 的内容与备份时不一致", part]];
            }
        }
        report(@"完成");
        return [WQBBackupResult successWithRecord:record];
    } progress:progress completion:completion];
}

#pragma mark - Delete

- (void)deleteBackup:(WQBBackupRecord *)record
          completion:(void (^)(BOOL, NSString *))completion
{
    if (![self beginOperation]) {
        [self deliver:^{ completion(NO, @"已有任务正在进行，请稍候"); }];
        return;
    }
    dispatch_async(_queue, ^{
        NSString *root = WQBBackupRoot();
        NSString *path = record.path.stringByStandardizingPath;
        BOOL ok = NO;
        NSString *error = nil;
        if (![path hasPrefix:[root stringByAppendingString:@"/"]]) {
            error = @"拒绝删除备份目录以外的内容";
        } else if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            error = @"备份已经不存在";
        } else {
            NSError *removeError = nil;
            ok = [NSFileManager.defaultManager removeItemAtPath:path error:&removeError];
            if (!ok) error = removeError.localizedDescription ?: @"无法删除备份";
            else wq_log(@"backup deleted: %@", path.lastPathComponent);
        }
        [self finishOperation];
        [self deliver:^{ completion(ok, error); }];
    });
}

#pragma mark - ZIP export

- (void)exportZIPForBackup:(WQBBackupRecord *)record
                  progress:(void (^)(NSString *))progress
                completion:(void (^)(NSString *, NSString *))completion
{
    [self runOperation:^WQBBackupResult *(void (^report)(NSString *)) {
        (void)report;
        return [self exportZIPNow:record progress:progress];
    } progress:nil completion:^(WQBBackupResult *result) {
        completion(result.success ? result.record.path : nil, result.errorText);
    }];
}

- (WQBBackupResult *)exportZIPNow:(WQBBackupRecord *)record progress:(void (^)(NSString *))progress
{
    WQBBackupKind kind = record.kind;
    NSArray *parts = nil;
    NSString *error = nil;
    if (!WQBValidateBackupFolder(record.path, &kind, &parts, &error))
        return [WQBBackupResult failure:error ?: @"备份无效"];
    if (record.bytes > kWQBMaxZipBytes)
        return [WQBBackupResult failure:@"备份超过 3.9 GB，无法打包成一个 ZIP。请在“文件”App 中查看备份文件夹，或只备份较小的数据。"];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"WQBackupExports"];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *name = [NSString stringWithFormat:@"%@-%@.zip", WQBFileName(record.appName), WQBBackupStampForDate(NSDate.date)];
    NSString *zipPath = [dir stringByAppendingPathComponent:name];
    [fm removeItemAtPath:zipPath error:nil];
    NSMutableArray<NSString *> *paths = [NSMutableArray new];
    NSString *manifest = [record.path stringByAppendingPathComponent:WQBBackupManifestName];
    if ([fm fileExistsAtPath:manifest]) [paths addObject:manifest];
    for (NSString *part in parts) {
        NSString *path = [record.path stringByAppendingPathComponent:part];
        if ([fm fileExistsAtPath:path]) [paths addObject:path];
    }
    NSUInteger skipped = 0;
    BOOL ok = wq_zip_write(paths, zipPath, wq_archive_posix_io(), ^BOOL { return [self cancelledNow]; },
        ^(unsigned long long bytes) {
            if (progress) progress([NSString stringWithFormat:@"正在打包… %@", WQBFormatBytes(bytes)]);
        }, &skipped, &error);
    if (!ok || [self cancelledNow]) {
        [fm removeItemAtPath:zipPath error:nil];
        return [WQBBackupResult failure:[self cancelledNow] ? @"已取消" : (error ?: @"打包失败")];
    }
    // The ZIP path travels in the record's path field to keep the result type
    // small; the UI treats it as a file URL.
    WQBBackupRecord *exported = [WQBBackupRecord new];
    exported.path = zipPath;
    exported.name = name;
    wq_log(@"zip export %@ -> %@", record.name, name);
    return [WQBBackupResult successWithRecord:exported];
}

@end
