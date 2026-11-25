//
//  WQBPaths.m
//  WQ Backup
//

#import "WQBPaths.h"
#import <CommonCrypto/CommonDigest.h>
#import <errno.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

NSString *const WQBBackupManifestName = @".wqbbackup.plist";
NSString *const WQBBackupFormatKey = @"Format";

static NSString *WQBKindString(WQBBackupKind kind)
{
    return kind == WQBBackupKindLiveContainer ? @"LiveContainer" : @"Local";
}

NSString *WQBKindName(WQBBackupKind kind) { return WQBKindString(kind); }

NSString *WQBKindDisplayName(WQBBackupKind kind)
{
    return kind == WQBBackupKindLiveContainer ? @"LiveContainer 应用" : @"本机应用";
}

BOOL WQBIsValidBundleID(NSString *bundleID)
{
    if (![bundleID isKindOfClass:NSString.class] || bundleID.length < 3 || bundleID.length > 255) return NO;
    if ([bundleID hasPrefix:@"."] || [bundleID hasSuffix:@"."] || [bundleID containsString:@".."]) return NO;
    static NSCharacterSet *bad;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = [[NSCharacterSet characterSetWithCharactersInString:
                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"] invertedSet];
    });
    return [bundleID containsString:@"."] && [bundleID rangeOfCharacterFromSet:bad].location == NSNotFound;
}

static NSString *WQBShortHash(NSString *text)
{
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:12];
    for (NSUInteger i = 0; i < 6; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

NSString *WQBSafeName(NSString *name)
{
    if (![name isKindOfClass:NSString.class] || !name.length) return @"item";
    NSMutableString *out = [NSMutableString stringWithCapacity:MIN(name.length, (NSUInteger)96)];
    for (NSUInteger i = 0; i < name.length && out.length < 96; i++) {
        unichar c = [name characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
            c == '.' || c == '-' || c == '_') {
            [out appendFormat:@"%C", c];
        } else {
            [out appendString:@"_"];
        }
    }
    if (!out.length) return @"item";
    if ([out isEqualToString:@"."] || [out isEqualToString:@".."]) return @"item";
    if ([out hasPrefix:@"."]) out = [[@"x" stringByAppendingString:out] mutableCopy];
    return out;
}

NSString *WQBFileName(NSString *name)
{
    if (![name isKindOfClass:NSString.class] || !name.length) return @"backup";
    NSMutableString *out = [NSMutableString stringWithCapacity:MIN(name.length, (NSUInteger)80)];
    for (NSUInteger i = 0; i < name.length && out.length < 80; i++) {
        unichar c = [name characterAtIndex:i];
        if (c == '/' || c == '\\' || c == ':' || c == 0 || c < 0x20 || c == 0x7f) continue;
        [out appendFormat:@"%C", c];
    }
    NSString *trimmed = [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length || [trimmed isEqualToString:@"."] || [trimmed isEqualToString:@".."]) return @"backup";
    return trimmed;
}

NSString *WQBLocalBackupKey(NSString *bundleID)
{
    return WQBSafeName(bundleID);
}

NSString *WQBGuestBackupKey(NSString *bundleID, NSString *containerFolder)
{
    NSString *folder = containerFolder.length ? containerFolder : @"default";
    return [NSString stringWithFormat:@"%@~%@~%@", WQBSafeName(bundleID), WQBSafeName(folder), WQBShortHash(folder)];
}

NSString *WQBBackupRoot(void)
{
    const char *override = getenv("WQB_BACKUP_ROOT");
    if (override && override[0]) return [NSString stringWithUTF8String:override];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs.length) docs = NSTemporaryDirectory();
    return [docs stringByAppendingPathComponent:@"WQBackups"];
}

NSString *WQBBackupRootForKind(WQBBackupKind kind)
{
    return [WQBBackupRoot() stringByAppendingPathComponent:
            (kind == WQBBackupKindLiveContainer ? @"LiveContainer" : @"Local")];
}

NSString *WQBBackupKeyFolder(WQBBackupKind kind, NSString *key)
{
    return [WQBBackupRootForKind(kind) stringByAppendingPathComponent:key];
}

NSArray<NSString *> *WQBBackupParts(void)
{
    return @[@"Documents", @"Library"];
}

NSString *WQBFormatBytes(unsigned long long bytes)
{
    static NSString *const units[] = {@"B", @"KB", @"MB", @"GB", @"TB"};
    double value = (double)bytes;
    NSUInteger unit = 0;
    while (value >= 1000.0 && unit < 4) { value /= 1000.0; unit++; }
    if (unit == 0) return [NSString stringWithFormat:@"%llu B", bytes];
    return [NSString stringWithFormat:@"%.1f %@", value, units[unit]];
}

NSString *WQBBackupStampForDate(NSDate *date)
{
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd HH.mm.ss";
    return [formatter stringFromDate:date ?: NSDate.date];
}

BOOL WQBTreeStats(NSString *path, unsigned long long *bytesOut, NSUInteger *filesOut,
                  NSString **errorText)
{
    if (bytesOut) *bytesOut = 0;
    if (filesOut) *filesOut = 0;
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) {
        if (errorText) *errorText = [NSString stringWithFormat:@"无法读取 %@（errno %d）", path.lastPathComponent, errno];
        return NO;
    }
    if (!S_ISDIR(st.st_mode)) {
        if (errorText) *errorText = [NSString stringWithFormat:@"%@ 不是文件夹", path.lastPathComponent];
        return NO;
    }
    unsigned long long bytes = 0;
    NSUInteger files = 0;
    NSMutableArray<NSString *> *pending = [NSMutableArray arrayWithObject:path];
    NSFileManager *fm = NSFileManager.defaultManager;
    while (pending.count) {
        NSString *dir = pending.lastObject;
        [pending removeLastObject];
        NSError *error = nil;
        NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:dir error:&error];
        if (!names) {
            if (errorText) *errorText = error.localizedDescription ?: [NSString stringWithFormat:@"无法读取 %@", dir.lastPathComponent];
            return NO;
        }
        for (NSString *name in names) {
            NSString *child = [dir stringByAppendingPathComponent:name];
            struct stat childStat;
            if (lstat(child.fileSystemRepresentation, &childStat) != 0) {
                if (errorText) *errorText = [NSString stringWithFormat:@"无法检查 %@（errno %d）", name, errno];
                return NO;
            }
            if (S_ISDIR(childStat.st_mode)) [pending addObject:child];
            else if (S_ISREG(childStat.st_mode)) {
                files++;
                bytes += (unsigned long long)childStat.st_size;
            }
        }
    }
    if (bytesOut) *bytesOut = bytes;
    if (filesOut) *filesOut = files;
    return YES;
}

#pragma mark - Manifest

BOOL WQBWriteManifest(NSString *dir, NSDictionary *manifest, NSString **errorText)
{
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:manifest
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0 error:nil];
    if (!data) {
        if (errorText) *errorText = @"无法编码备份清单";
        return NO;
    }
    NSString *path = [dir stringByAppendingPathComponent:WQBBackupManifestName];
    if (![data writeToFile:path options:NSDataWritingAtomic error:nil]) {
        if (errorText) *errorText = @"无法写入备份清单";
        return NO;
    }
    return YES;
}

NSDictionary *WQBReadManifest(NSString *dir)
{
    id plist = [NSDictionary dictionaryWithContentsOfFile:
                [dir stringByAppendingPathComponent:WQBBackupManifestName]];
    return [plist isKindOfClass:NSDictionary.class] ? plist : nil;
}

static BOOL WQBIsInteger(id value)
{
    if (![value isKindOfClass:NSNumber.class]) return NO;
    const char *type = [(NSNumber *)value objCType];
    return strcmp(type, @encode(char)) == 0 || strcmp(type, @encode(unsigned char)) == 0 ||
           strcmp(type, @encode(short)) == 0 || strcmp(type, @encode(unsigned short)) == 0 ||
           strcmp(type, @encode(int)) == 0 || strcmp(type, @encode(unsigned int)) == 0 ||
           strcmp(type, @encode(long)) == 0 || strcmp(type, @encode(unsigned long)) == 0 ||
           strcmp(type, @encode(long long)) == 0 || strcmp(type, @encode(unsigned long long)) == 0;
}

BOOL WQBValidateBackupFolder(NSString *dir, WQBBackupKind *kindOut, NSArray<NSString *> **partsOut,
                             NSString **errorText)
{
    NSString *manifestPath = [dir stringByAppendingPathComponent:WQBBackupManifestName];
    struct stat st;
    if (lstat(manifestPath.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) {
        if (errorText) *errorText = @"缺少备份清单（未完成的备份）";
        return NO;
    }
    NSDictionary *manifest = WQBReadManifest(dir);
    if (!manifest) {
        if (errorText) *errorText = @"备份清单无法读取";
        return NO;
    }
    if (![manifest[@"Complete"] isKindOfClass:NSNumber.class] || ![manifest[@"Complete"] boolValue]) {
        if (errorText) *errorText = @"备份未标记为完成";
        return NO;
    }
    if (!WQBIsInteger(manifest[WQBBackupFormatKey]) || [manifest[WQBBackupFormatKey] integerValue] != 1) {
        if (errorText) *errorText = @"备份格式不受支持";
        return NO;
    }
    NSString *kindName = manifest[@"Kind"];
    WQBBackupKind kind = [kindName isEqual:@"LiveContainer"] ? WQBBackupKindLiveContainer : WQBBackupKindLocal;
    if (![kindName isEqual:@"Local"] && ![kindName isEqual:@"LiveContainer"]) {
        if (errorText) *errorText = @"备份类型无效";
        return NO;
    }
    if (!WQBIsValidBundleID(manifest[@"BundleID"])) {
        if (errorText) *errorText = @"备份里的 Bundle ID 无效";
        return NO;
    }
    if (![manifest[@"Created"] isKindOfClass:NSDate.class]) {
        if (errorText) *errorText = @"备份没有有效的时间";
        return NO;
    }
    NSArray *parts = manifest[@"Parts"];
    NSArray *allowed = WQBBackupParts();
    if (![parts isKindOfClass:NSArray.class]) {
        if (errorText) *errorText = @"备份清单缺少数据部分";
        return NO;
    }
    NSMutableArray<NSString *> *canonical = [NSMutableArray new];
    for (NSString *part in allowed) {
        if ([parts containsObject:part]) [canonical addObject:part];
    }
    if (canonical.count != parts.count) {
        if (errorText) *errorText = @"备份清单包含无效或重复的数据部分";
        return NO;
    }
    for (NSString *part in canonical) {
        NSString *partPath = [dir stringByAppendingPathComponent:part];
        if (lstat(partPath.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) {
            if (errorText) *errorText = [NSString stringWithFormat:@"备份缺少 %@ 文件夹", part];
            return NO;
        }
    }
    id stats = manifest[@"PartStats"];
    if (stats) {
        if (![stats isKindOfClass:NSDictionary.class]) {
            if (errorText) *errorText = @"备份清单的文件统计无效";
            return NO;
        }
        for (NSString *part in canonical) {
            NSDictionary *partStats = stats[part];
            if (![partStats isKindOfClass:NSDictionary.class] ||
                !WQBIsInteger(partStats[@"Files"]) || !WQBIsInteger(partStats[@"Bytes"])) {
                if (errorText) *errorText = [NSString stringWithFormat:@"备份清单的 %@ 统计无效", part];
                return NO;
            }
        }
    }
    if (kindOut) *kindOut = kind;
    if (partsOut) *partsOut = canonical;
    return YES;
}

BOOL WQBVerifyBackupStats(NSString *dir, NSString **errorText)
{
    NSDictionary *manifest = WQBReadManifest(dir);
    NSDictionary *stats = manifest[@"PartStats"];
    if (![stats isKindOfClass:NSDictionary.class]) {
        if (errorText) *errorText = @"备份没有记录文件统计，无法校验";
        return NO;
    }
    for (NSString *part in WQBBackupParts()) {
        NSDictionary *partStats = stats[part];
        if (!partStats) continue;
        unsigned long long bytes = 0;
        NSUInteger files = 0;
        NSString *error = nil;
        if (!WQBTreeStats([dir stringByAppendingPathComponent:part], &bytes, &files, &error)) {
            if (errorText) *errorText = error;
            return NO;
        }
        if (bytes != [partStats[@"Bytes"] unsignedLongLongValue] ||
            files != [partStats[@"Files"] unsignedIntegerValue]) {
            if (errorText) *errorText = [NSString stringWithFormat:
                                         @"%@ 与备份时不一致（现在 %lu 个文件 / %llu 字节）",
                                         part, (unsigned long)files, bytes];
            return NO;
        }
    }
    return YES;
}

#pragma mark - Record

@implementation WQBBackupRecord

- (NSString *)dateText
{
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    return [formatter stringFromDate:_created ?: NSDate.distantPast];
}

- (NSString *)sizeText { return WQBFormatBytes(_bytes); }

- (NSString *)detailText
{
    if (!_complete) return _validationError ?: @"未完成的备份";
    NSMutableArray *parts = [NSMutableArray new];
    [parts addObject:WQBFormatBytes(_bytes)];
    [parts addObject:[NSString stringWithFormat:@"%lu 个文件", (unsigned long)_files]];
    if (_parts.count) [parts addObject:[_parts componentsJoinedByString:@" + "]];
    return [parts componentsJoinedByString:@" · "];
}

+ (instancetype)recordAtFolder:(NSString *)folder kind:(WQBBackupKind)kind
{
    NSFileManager *fm = NSFileManager.defaultManager;
    struct stat st;
    if (lstat(folder.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) return nil;
    WQBBackupKind actual = kind;
    NSArray *parts = nil;
    NSString *error = nil;
    BOOL valid = WQBValidateBackupFolder(folder, &actual, &parts, &error);
    NSDictionary *manifest = WQBReadManifest(folder);
    BOOL hasContent = [fm fileExistsAtPath:[folder stringByAppendingPathComponent:@"Documents"]] ||
                      [fm fileExistsAtPath:[folder stringByAppendingPathComponent:@"Library"]];
    if (!valid && !hasContent && !manifest) return nil;
    WQBBackupRecord *record = [WQBBackupRecord new];
    record.path = folder;
    record.name = folder.lastPathComponent;
    record.kind = actual;
    record.key = [manifest[@"Key"] isKindOfClass:NSString.class] ? manifest[@"Key"] : @"";
    record.bundleID = [manifest[@"BundleID"] isKindOfClass:NSString.class] ? manifest[@"BundleID"] : @"";
    record.appName = [manifest[@"AppName"] isKindOfClass:NSString.class] ? manifest[@"AppName"] : record.bundleID;
    record.containerFolder = [manifest[@"ContainerFolder"] isKindOfClass:NSString.class] ? manifest[@"ContainerFolder"] : nil;
    record.containerLabel = [manifest[@"ContainerLabel"] isKindOfClass:NSString.class] ? manifest[@"ContainerLabel"] : nil;
    record.sourceContainer = [manifest[@"SourceContainer"] isKindOfClass:NSString.class] ? manifest[@"SourceContainer"] : nil;
    record.parts = parts ?: @[];
    record.complete = valid;
    record.validationError = valid ? nil : (error ?: @"备份无效");
    if ([manifest[@"Created"] isKindOfClass:NSDate.class]) {
        record.created = manifest[@"Created"];
    } else {
        record.created = [fm attributesOfItemAtPath:folder error:nil][NSFileModificationDate] ?: NSDate.distantPast;
    }
    NSDictionary *stats = [manifest[@"PartStats"] isKindOfClass:NSDictionary.class] ? manifest[@"PartStats"] : nil;
    if (stats) {
        for (NSString *part in record.parts) {
            NSDictionary *partStats = stats[part];
            if (![partStats isKindOfClass:NSDictionary.class]) continue;
            record.bytes += [partStats[@"Bytes"] unsignedLongLongValue];
            record.files += [partStats[@"Files"] unsignedIntegerValue];
        }
    } else if (valid) {
        unsigned long long bytes = 0;
        NSUInteger files = 0;
        for (NSString *part in record.parts) {
            if (WQBTreeStats([folder stringByAppendingPathComponent:part], &bytes, &files, nil)) {
                record.bytes += bytes;
                record.files += files;
            }
        }
    }
    return record;
}

+ (NSArray<WQBBackupRecord *> *)recordsInKeyFolder:(NSString *)folder kind:(WQBBackupKind)kind
{
    NSMutableArray<WQBBackupRecord *> *records = [NSMutableArray new];
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil];
    for (NSString *name in names) {
        if ([name hasPrefix:@"."]) continue;
        WQBBackupRecord *record = [self recordAtFolder:[folder stringByAppendingPathComponent:name] kind:kind];
        if (record) [records addObject:record];
    }
    [records sortUsingComparator:^NSComparisonResult(WQBBackupRecord *a, WQBBackupRecord *b) {
        NSComparisonResult order = [b.created compare:a.created];
        if (order != NSOrderedSame) return order;
        return [b.name compare:a.name options:NSNumericSearch];
    }];
    return records;
}

@end
