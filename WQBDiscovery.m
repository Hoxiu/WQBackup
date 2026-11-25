//
//  WQBDiscovery.m
//  WQ Backup
//

#import "WQBDiscovery.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import <errno.h>
#import <sys/stat.h>

static NSString *WQBCanonical(NSString *path)
{
    NSString *standard = path.stringByStandardizingPath;
    if ([standard isEqualToString:@"/var"] || [standard hasPrefix:@"/var/"])
        return [@"/private" stringByAppendingString:standard];
    return standard;
}

static BOOL WQBIsDirectory(NSString *path)
{
    struct stat st;
    return lstat(WQBCanonical(path).fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode);
}

static void WQBGrantPath(NSString *path)
{
    NSString *candidate = path.stringByStandardizingPath;
    for (NSUInteger depth = 0; depth < 8 && candidate.length > 1; depth++) {
        if (wq_grant(candidate)) return;
        candidate = candidate.stringByDeletingLastPathComponent;
    }
}

static BOOL WQBIsSafeComponent(NSString *name)
{
    if (![name isKindOfClass:NSString.class] || !name.length) return NO;
    if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) return NO;
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        if (c == '/' || c == 0 || c < 0x20) return NO;
    }
    return YES;
}

static NSDictionary *WQBReadPlist(NSString *path)
{
    NSString *error = nil;
    NSData *data = wq_read(path, 8 * 1024 * 1024, &error);
    if (!data.length) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil];
    return [plist isKindOfClass:NSDictionary.class] ? plist : nil;
}

static NSString *WQBString(id value)
{
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSString *WQBAppDisplayName(NSDictionary *info, NSString *fallback)
{
    for (NSString *key in @[@"CFBundleDisplayName", @"CFBundleName", @"CFBundleExecutable"]) {
        NSString *value = WQBString(info[key]);
        if (value.length) return value;
    }
    return fallback.length ? fallback : @"未知应用";
}

static NSArray<WQBBackupRecord *> *WQBRecordsForTarget(WQBBackupKind kind, NSString *key)
{
    return [WQBBackupRecord recordsInKeyFolder:WQBBackupKeyFolder(kind, key) kind:kind];
}

NSString *WQBOriginText(WQBAppOrigin origin)
{
    switch (origin) {
        case WQBAppOriginSystem: return @"系统应用";
        case WQBAppOriginUser: return @"我安装的应用";
        default: return @"来源未知";
    }
}

WQBAppOrigin WQBAppOriginForBundle(NSString *bundleID, NSString *bundlePath)
{
    NSString *path = bundlePath.length ? WQBCanonical(bundlePath) : @"";
    if ([path hasPrefix:@"/private/var/containers/Bundle/Application/"]) return WQBAppOriginUser;
    if ([path hasPrefix:@"/Applications/"] ||
        [path hasPrefix:@"/private/var/staged_system_apps/"] ||
        [path hasPrefix:@"/System/"] ||
        [path hasPrefix:@"/private/System/"]) return WQBAppOriginSystem;
    return [bundleID hasPrefix:@"com.apple."] ? WQBAppOriginSystem : WQBAppOriginUser;
}

@implementation WQBAppTarget

- (void)reloadBackups
{
    self.backups = WQBRecordsForTarget(self.kind, self.key);
}

- (NSString *)subtitleText
{
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    if (self.kind == WQBBackupKindLocal) [parts addObject:WQBOriginText(self.origin)];
    else [parts addObject:@"LiveContainer 应用"];
    if (self.bundleID.length) [parts addObject:self.bundleID];
    if (self.kind == WQBBackupKindLiveContainer && self.lcContainerLabel.length) {
        NSString *label = self.lcContainerLabel;
        if (label.length > 16) label = [[label substringToIndex:8] stringByAppendingString:@"…"];
        [parts addObject:[@"容器: " stringByAppendingString:label]];
    }
    if (self.note.length) [parts addObject:self.note];
    return [parts componentsJoinedByString:@" · "];
}

- (NSString *)backupSummaryText
{
    WQBBackupRecord *latest = nil;
    for (WQBBackupRecord *record in self.backups) if (record.complete) { latest = record; break; }
    if (!latest) latest = self.backups.firstObject;
    if (!latest) return self.available ? @"尚无备份" : @"不可备份";
    return [NSString stringWithFormat:@"上次备份 %@ · %@", latest.dateText, latest.sizeText];
}

@end

@implementation WQBLiveContainerRoot
@end

static WQBLiveContainerRoot *WQBMakeRoot(NSString *path, NSString *grantRoot, BOOL isAppGroup,
                                           NSString *ownerID, NSString *ownerName)
{
    WQBLiveContainerRoot *root = [WQBLiveContainerRoot new];
    root.path = path;
    root.grantRoot = grantRoot;
    root.isAppGroup = isAppGroup;
    root.ownerID = ownerID ?: @"";
    root.ownerName = ownerName ?: @"LiveContainer";
    return root;
}

NSArray<WQBLiveContainerRoot *> *WQBLiveContainerRootsInContainer(NSString *containerPath)
{
    NSString *container = WQBCanonical(containerPath);
    wq_grant(container);
    if (!WQBIsDirectory(container)) return @[];
    NSString *documents = [container stringByAppendingPathComponent:@"Documents"];
    BOOL hasApps = WQBIsDirectory([documents stringByAppendingPathComponent:@"Applications"]);
    BOOL hasData = WQBIsDirectory([documents stringByAppendingPathComponent:@"Data/Application"]);
    // A LiveContainer that has never run an app has neither folder; there is
    // nothing to back up there. Skipping it also avoids a label lookup (a
    // token and a container-manager query) for every other app container.
    if (!hasApps && !hasData) return @[];
    NSString *owner = wq_container_label(container);
    if (!owner.length) owner = wq_bundle_id_for_container(container);
    NSString *ownerName = owner.length ? (wq_display_name(owner) ?: owner) : @"LiveContainer";
    WQBLiveContainerRoot *root = WQBMakeRoot(documents, container, NO, owner, ownerName);
    return @[root];
}

NSArray<WQBLiveContainerRoot *> *WQBLiveContainerRootsInGroupContainer(NSString *groupPath)
{
    NSString *group = WQBCanonical(groupPath);
    wq_grant(group);
    if (!WQBIsDirectory(group)) return @[];
    NSString *lc = [group stringByAppendingPathComponent:@"LiveContainer"];
    BOOL hasApps = WQBIsDirectory([lc stringByAppendingPathComponent:@"Applications"]);
    BOOL hasData = WQBIsDirectory([lc stringByAppendingPathComponent:@"Data/Application"]);
    if (!hasApps && !hasData) return @[];
    NSString *owner = wq_group_id_for_container(group);
    WQBLiveContainerRoot *root = WQBMakeRoot(lc, group, YES, owner ?: group.lastPathComponent,
                                             owner ?: @"LiveContainer 共享容器");
    return @[root];
}

// Adds the container target for `folder` below the first matching root.
// Shared containers live in a LiveContainer App Group; non-shared ones in the
// LiveContainer data container. Returns nil when no folder exists.
static WQBAppTarget *WQBGuestTargetForFolder(NSString *bundleID, NSString *appName, NSString *appFolder,
                                              NSString *folderName, NSString *label, BOOL shared,
                                              WQBLiveContainerRoot *root,
                                              NSArray<WQBLiveContainerRoot *> *allRoots)
{
    if (!WQBIsSafeComponent(folderName)) return nil;
    NSMutableArray<WQBLiveContainerRoot *> *candidates = [NSMutableArray new];
    if ((shared && root.isAppGroup) || (!shared && !root.isAppGroup)) [candidates addObject:root];
    for (WQBLiveContainerRoot *candidate in allRoots) {
        if (shared != candidate.isAppGroup) continue;
        if (![candidates containsObject:candidate]) [candidates addObject:candidate];
    }
    if (!candidates.count) [candidates addObject:root];
    for (WQBLiveContainerRoot *candidate in candidates) {
        NSString *path = [[[candidate.path stringByAppendingPathComponent:@"Data/Application"]
                           stringByAppendingPathComponent:folderName] copy];
        wq_grant(candidate.grantRoot);
        WQBGrantPath(path);
        if (!WQBIsDirectory(path)) continue;
        BOOL hasDocuments = WQBIsDirectory([path stringByAppendingPathComponent:@"Documents"]);
        BOOL hasLibrary = WQBIsDirectory([path stringByAppendingPathComponent:@"Library"]);
        WQBAppTarget *target = [WQBAppTarget new];
        target.kind = WQBBackupKindLiveContainer;
        target.name = appName;
        target.bundleID = bundleID;
        target.key = WQBGuestBackupKey(bundleID, folderName);
        target.containerPath = path;
        target.lcRootPath = candidate.path;
        target.lcAppFolder = appFolder;
        target.lcContainerFolder = folderName;
        target.lcContainerLabel = label.length ? label : folderName;
        target.lcOwnerName = candidate.ownerName;
        target.origin = WQBAppOriginUser;
        target.bundlePath = appFolder;
        target.available = hasDocuments || hasLibrary;
        if (!target.available) target.note = @"数据文件夹里没有 Documents 或 Library";
        [target reloadBackups];
        return target;
    }
    return nil;
}

NSArray<WQBAppTarget *> *WQBGuestTargetsInRoot(WQBLiveContainerRoot *root,
                                                NSArray<WQBLiveContainerRoot *> *allRoots)
{
    if (!root) return @[];
    wq_grant(root.grantRoot);
    if (!WQBIsDirectory(root.path)) return @[];
    NSString *appsDir = [root.path stringByAppendingPathComponent:@"Applications"];
    NSString *listError = nil;
    NSArray<NSString *> *names = wq_list(appsDir, &listError);
    if (!names) return @[];
    NSMutableArray<WQBAppTarget *> *targets = [NSMutableArray new];
    for (NSString *folderName in [names sortedArrayUsingSelector:@selector(compare:)]) {
        if ([folderName hasPrefix:@"."]) continue;
        NSString *appFolder = [appsDir stringByAppendingPathComponent:folderName];
        if (!WQBIsDirectory(appFolder)) continue;
        NSDictionary *info = WQBReadPlist([appFolder stringByAppendingPathComponent:@"Info.plist"]);
        NSDictionary *lcInfo = WQBReadPlist([appFolder stringByAppendingPathComponent:@"LCAppInfo.plist"]);
        NSString *displayName = WQBAppDisplayName(info, folderName);
        NSString *bundleID = WQBString(info[@"CFBundleIdentifier"]);
        if (!WQBIsValidBundleID(bundleID)) bundleID = WQBString(lcInfo[@"LCOrignalBundleIdentifier"]);
        if (!WQBIsValidBundleID(bundleID) && [folderName hasSuffix:@".app"])
            bundleID = WQBString(folderName.stringByDeletingPathExtension);
        if (!WQBIsValidBundleID(bundleID) && WQBIsValidBundleID(folderName)) bundleID = folderName;
        if (!WQBIsValidBundleID(bundleID)) continue;
        if ([bundleID isEqualToString:NSBundle.mainBundle.bundleIdentifier]) continue;   // never back up ourselves

        NSMutableArray<NSDictionary *> *wanted = [NSMutableArray new];   // folder/label/shared
        NSMutableSet<NSString *> *wantedFolders = [NSMutableSet new];
        void (^want)(NSString *, NSString *, BOOL) = ^(NSString *folder, NSString *label, BOOL shared) {
            if (!WQBIsSafeComponent(folder) || [wantedFolders containsObject:folder]) return;
            [wantedFolders addObject:folder];
            [wanted addObject:@{ @"folder": folder, @"label": label ?: folder, @"shared": @(shared) }];
        };
        NSArray *containers = [lcInfo[@"LCContainers"] isKindOfClass:NSArray.class] ? lcInfo[@"LCContainers"] : @[];
        NSMutableDictionary<NSString *, NSString *> *containerNames = [NSMutableDictionary new];
        for (id entry in containers) {
            if (![entry isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *dict = entry;
            NSString *folder = WQBString(dict[@"folderName"]);
            NSString *label = WQBString(dict[@"name"]);
            BOOL shared = [dict[@"isShared"] boolValue];
            if (folder.length && label.length) containerNames[folder] = label;
            if (!folder.length) {
                if (dict[@"bookmarkData"]) {
                    [wanted addObject:@{ @"folder": @"", @"label": label.length ? label : @"外部数据文件夹",
                                         @"shared": @(shared), @"external": @YES }];
                }
                continue;
            }
            if (!label.length) label = folder;
            want(folder, label, shared);
        }
        NSString *defaultFolder = WQBString(lcInfo[@"LCDataUUID"]);
        if (defaultFolder.length)
            want(defaultFolder, containerNames[defaultFolder] ?: @"默认容器", root.isAppGroup);
        // LiveContainer 2.x and earlier kept the data inside the app folder,
        // either below Data/ or directly in the bundle folder.
        NSString *legacy = [appFolder stringByAppendingPathComponent:@"Data"];
        BOOL hasLegacy = WQBIsDirectory([legacy stringByAppendingPathComponent:@"Documents"]) ||
                         WQBIsDirectory([legacy stringByAppendingPathComponent:@"Library"]);
        if (!hasLegacy) {
            legacy = appFolder;
            hasLegacy = WQBIsDirectory([legacy stringByAppendingPathComponent:@"Documents"]) ||
                        WQBIsDirectory([legacy stringByAppendingPathComponent:@"Library"]);
        }
        if (hasLegacy) {
            WQBAppTarget *target = [WQBAppTarget new];
            target.kind = WQBBackupKindLiveContainer;
            target.name = displayName;
            target.bundleID = bundleID;
            target.key = WQBGuestBackupKey(bundleID, @"legacy");
            target.containerPath = legacy;
            target.lcRootPath = root.path;
            target.lcAppFolder = appFolder;
            target.lcContainerFolder = @"legacy";
            target.lcContainerLabel = @"旧版数据";
            target.lcOwnerName = root.ownerName;
            target.origin = WQBAppOriginUser;
            target.bundlePath = appFolder;
            target.available = YES;
            [target reloadBackups];
            [targets addObject:target];
        }
        NSUInteger added = 0;
        NSMutableSet<NSString *> *seenPaths = [NSMutableSet new];
        NSMutableSet<NSString *> *seenKeys = [NSMutableSet new];
        for (NSDictionary *entry in wanted) {
            NSString *folder = entry[@"folder"];
            NSString *label = entry[@"label"];
            BOOL external = [entry[@"external"] boolValue];
            WQBAppTarget *target = external ? nil : WQBGuestTargetForFolder(bundleID, displayName, appFolder,
                                                                            folder, label,
                                                                            [entry[@"shared"] boolValue], root, allRoots);
            if (target) {
                if ([seenPaths containsObject:target.containerPath]) continue;
                [seenPaths addObject:target.containerPath];
                [targets addObject:target];
                added++;
                continue;
            }
            // A container that LiveContainer knows about but this app can't
            // reach: an external bookmark folder, a deleted folder, or data
            // that has not been created yet. Show it instead of hiding it.
            NSString *keyFolder = folder.length ? folder : [@"external-" stringByAppendingString:label ?: @"?"];
            NSString *key = WQBGuestBackupKey(bundleID, keyFolder);
            if ([seenKeys containsObject:key]) continue;
            [seenKeys addObject:key];
            WQBAppTarget *missing = [WQBAppTarget new];
            missing.kind = WQBBackupKindLiveContainer;
            missing.name = displayName;
            missing.bundleID = bundleID;
            missing.key = key;
            missing.containerPath = appFolder;
            missing.lcRootPath = root.path;
            missing.lcAppFolder = appFolder;
            missing.lcContainerFolder = folder ?: @"";
            missing.lcContainerLabel = label.length ? label : @"外部数据";
            missing.lcOwnerName = root.ownerName;
            missing.origin = WQBAppOriginUser;
            missing.bundlePath = appFolder;
            missing.available = NO;
            missing.note = external
                ? @"LiveContainer 的外部数据文件夹，需要 LiveContainer 自己的书签授权，本软件无法读取"
                : @"数据文件夹不存在（可能已删除、还未运行过，或位于外部数据文件夹）";
            [missing reloadBackups];
            [targets addObject:missing];
        }
        if (!added && !wanted.count && !hasLegacy) {
            WQBAppTarget *target = [WQBAppTarget new];
            target.kind = WQBBackupKindLiveContainer;
            target.name = displayName;
            target.bundleID = bundleID;
            target.key = WQBGuestBackupKey(bundleID, @"missing");
            target.containerPath = appFolder;
            target.lcRootPath = root.path;
            target.lcAppFolder = appFolder;
            target.lcContainerFolder = @"";
            target.lcContainerLabel = @"无数据";
            target.lcOwnerName = root.ownerName;
            target.origin = WQBAppOriginUser;
            target.bundlePath = appFolder;
            target.available = NO;
            target.note = @"还没有数据容器，请先在 LiveContainer 中运行一次；外部数据文件夹无法由此软件读取";
            [target reloadBackups];
            [targets addObject:target];
        }
    }
    [targets sortUsingComparator:^NSComparisonResult(WQBAppTarget *a, WQBAppTarget *b) {
        NSComparisonResult order = [a.name localizedCaseInsensitiveCompare:b.name];
        if (order != NSOrderedSame) return order;
        return [(a.lcContainerLabel ?: @"") localizedCaseInsensitiveCompare:(b.lcContainerLabel ?: @"")];
    }];
    return targets;
}

NSArray<WQBAppTarget *> *WQBLocalTargetsFromContainers(NSArray<NSString *> *containers, NSString *ownHome)
{
    NSString *own = ownHome ? WQBCanonical(ownHome) : nil;
    NSMutableArray<WQBAppTarget *> *targets = [NSMutableArray new];
    NSMutableSet<NSString *> *seen = [NSMutableSet new];
    for (NSString *containerPath in containers) {
        if (![containerPath isKindOfClass:NSString.class] || !containerPath.length) continue;
        NSString *container = WQBCanonical(containerPath);
        if (own.length && [container isEqualToString:own]) continue;   // this app itself
        if ([seen containsObject:container]) continue;
        [seen addObject:container];
        BOOL granted = wq_grant(container);
        if (!WQBIsDirectory(container)) continue;
        NSString *bundleID = wq_container_label(container);
        if (!WQBIsValidBundleID(bundleID)) bundleID = wq_bundle_id_for_container(container);
        if (!WQBIsValidBundleID(bundleID)) continue;
        BOOL hasDocuments = WQBIsDirectory([container stringByAppendingPathComponent:@"Documents"]);
        BOOL hasLibrary = WQBIsDirectory([container stringByAppendingPathComponent:@"Library"]);
        if (granted && !hasDocuments && !hasLibrary) continue;
        NSString *bundlePath = wq_bundle_path_for_id(bundleID);
        WQBAppTarget *target = [WQBAppTarget new];
        target.kind = WQBBackupKindLocal;
        target.name = wq_display_name(bundleID) ?: bundleID;
        target.bundleID = bundleID;
        target.key = WQBLocalBackupKey(bundleID);
        target.containerPath = container;
        target.bundlePath = bundlePath;
        target.origin = WQBAppOriginForBundle(bundleID, bundlePath);
        target.available = granted && (hasDocuments || hasLibrary);
        if (!granted) target.note = @"无法取得该应用的访问权限";
        else if (!target.available) target.note = @"没有 Documents 或 Library";
        [target reloadBackups];
        [targets addObject:target];
    }
    [targets sortUsingComparator:^NSComparisonResult(WQBAppTarget *a, WQBAppTarget *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return targets;
}

@implementation WQBDiscovery

static NSArray<WQBAppTarget *> *gLocalCache;
static NSArray<WQBAppTarget *> *gGuestCache;
static NSString *gLocalNote;
static NSString *gGuestNote;
static CFAbsoluteTime gLocalAt;
static CFAbsoluteTime gGuestAt;
static const NSTimeInterval kCacheLifetime = 60;

+ (void)invalidateCache
{
    @synchronized (self) {
        gLocalCache = nil;
        gGuestCache = nil;
        gLocalNote = nil;
        gGuestNote = nil;
        gLocalAt = 0;
        gGuestAt = 0;
    }
}

+ (NSArray<WQBAppTarget *> *)discoverLocalAppsWithProgress:(void (^)(NSString *))progress
                                                      note:(NSString **)note
{
    @synchronized (self) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (gLocalCache && now - gLocalAt < kCacheLifetime) {
            if (note) *note = gLocalNote;
            return gLocalCache;
        }
        NSString *problem = nil;
        NSArray<WQBAppTarget *> *targets = @[];
        do {
            if (!wq_app_group()) {
                problem = @"没有获得 App Group。请用 AltStore、SideStore 或 Impactor 重新签名（保留 App Group 权限），否则无法读取其他应用的数据。";
                break;
            }
            if (!wq_display_names_loaded()) {
                if (progress) progress(@"正在读取应用名称…");
                wq_load_display_names();
            }
            if (progress) progress(@"正在查找本机应用…");
            NSArray<NSString *> *containers = wq_enumerate(@"/private/var/mobile/Containers/Data/Application", 0,
                nil, ^(int64_t done, int64_t total, NSUInteger found) {
                    if (!progress || total <= 0) return;
                    progress([NSString stringWithFormat:@"正在查找本机应用… %lld%%（%lu 个）",
                              (long long)(done * 100 / total), (unsigned long)found]);
                });
            if (!containers) {
                problem = wq_full_scan_was_declined()
                    ? @"需要扫描全部文件才能列出应用。请下拉刷新，并在提示中选“开始扫描”。"
                    : @"无法读取应用容器列表。设备可能需要解锁，或这个 iOS 版本已不再支持 worse_query。";
                break;
            }
            targets = WQBLocalTargetsFromContainers(containers, NSHomeDirectory());
            if (!targets.count) problem = @"没有找到可备份的本机应用。";
        } while (0);
        gLocalCache = targets;
        gLocalNote = problem;
        gLocalAt = CFAbsoluteTimeGetCurrent();
        if (note) *note = problem;
        return targets;
    }
}

+ (NSArray<WQBAppTarget *> *)discoverLiveContainerAppsWithProgress:(void (^)(NSString *))progress
                                                               note:(NSString **)note
{
    @synchronized (self) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (gGuestCache && now - gGuestAt < kCacheLifetime) {
            if (note) *note = gGuestNote;
            return gGuestCache;
        }
        NSString *problem = nil;
        NSMutableArray<WQBAppTarget *> *targets = [NSMutableArray new];
        do {
            if (!wq_app_group()) {
                problem = @"没有获得 App Group，无法读取 LiveContainer 的数据容器。";
                break;
            }
            if (!wq_display_names_loaded()) {
                if (progress) progress(@"正在读取应用名称…");
                wq_load_display_names();
            }
            if (progress) progress(@"正在查找 LiveContainer…");
            NSArray<NSString *> *appContainers = wq_enumerate(@"/private/var/mobile/Containers/Data/Application", 0, nil, nil);
            NSArray<NSString *> *groupContainers = wq_enumerate(@"/private/var/mobile/Containers/Shared/AppGroup", 0, nil, nil);
            NSMutableArray<WQBLiveContainerRoot *> *roots = [NSMutableArray new];
            NSMutableSet<NSString *> *seen = [NSMutableSet new];
            void (^addRoots)(NSArray<WQBLiveContainerRoot *> *) = ^(NSArray<WQBLiveContainerRoot *> *found) {
                for (WQBLiveContainerRoot *root in found) {
                    if (!root.path.length || [seen containsObject:root.path]) continue;
                    [seen addObject:root.path];
                    [roots addObject:root];
                }
            };
            for (NSString *container in appContainers) addRoots(WQBLiveContainerRootsInContainer(container));
            for (NSString *group in groupContainers) addRoots(WQBLiveContainerRootsInGroupContainer(group));
            if (!roots.count) {
                problem = @"没有发现 LiveContainer。请确认它已安装，并且至少运行过一个应用。";
                break;
            }
            [roots sortUsingComparator:^NSComparisonResult(WQBLiveContainerRoot *a, WQBLiveContainerRoot *b) {
                if (a.isAppGroup != b.isAppGroup) return a.isAppGroup ? NSOrderedDescending : NSOrderedAscending;
                return [a.path compare:b.path];
            }];
            NSUInteger index = 0;
            for (WQBLiveContainerRoot *root in roots) {
                index++;
                if (progress) progress([NSString stringWithFormat:@"正在读取 LiveContainer 应用（%lu/%lu）…",
                                        (unsigned long)index, (unsigned long)roots.count]);
                NSArray *found = WQBGuestTargetsInRoot(root, roots);
                [targets addObjectsFromArray:found];
            }
        } while (0);
        if (!targets.count && !problem) problem = @"LiveContainer 里没有找到已安装的应用。";
        NSArray *result = [targets copy];
        gGuestCache = result;
        gGuestNote = problem;
        gGuestAt = CFAbsoluteTimeGetCurrent();
        if (note) *note = problem;
        return result;
    }
}

@end
