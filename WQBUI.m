//
//  WQBUI.m
//  WQ Backup
//

#import "WQBUI.h"
#import "WQBDiscovery.h"
#import "WQBBackup.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import <sys/stat.h>

@interface WQBAppDetailViewController : UITableViewController
- (instancetype)initWithTarget:(WQBAppTarget *)target;
@end

static NSString *const kWQBVerifyContentsKey = @"WQBVerifyContents";
static NSString *const kWQBLastLocalCountKey = @"WQBLastLocalCount";
static NSString *const kWQBLastGuestCountKey = @"WQBLastGuestCount";
static NSString *const kWQBLastSystemCountKey = @"WQBLastSystemCount";
static NSString *const kWQBLastUserCountKey = @"WQBLastUserCount";
static NSString *const kWQBOriginFilterKey = @"WQBOriginFilter";
static NSString *const WQBAppIconsDidUpdateNotification = @"WQBAppIconsDidUpdate";

static UIColor *WQBAccentColor(void)
{
    return [UIColor colorWithRed:0.11 green:0.45 blue:0.88 alpha:1.0];
}

static UIWindow *WQBKeyWindow(void)
{
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) return window;
            if (!fallback) fallback = window;
        }
    }
    return fallback;
}

static UIViewController *WQBTopViewController(void)
{
    UIViewController *top = WQBKeyWindow().rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    // A presented alert/activity sheet cannot present another alert; go back
    // to the controller that owns it.
    while ([top isKindOfClass:UIAlertController.class] || [top isKindOfClass:UIActivityViewController.class])
        top = top.presentingViewController;
    for (NSInteger i = 0; i < 4 && top; i++) {
        if ([top isKindOfClass:UITabBarController.class])
            top = ((UITabBarController *)top).selectedViewController;
        else if ([top isKindOfClass:UINavigationController.class])
            top = ((UINavigationController *)top).topViewController;
        else
            break;
    }
    return top;
}

static void WQBAlert(NSString *title, NSString *message, UIViewController *from)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = from;
        if (!top || top.presentedViewController) top = WQBTopViewController();
        if (!top) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [top presentViewController:alert animated:YES completion:nil];
    });
}

static void WQBConfirm(NSString *title, NSString *message, NSString *actionTitle, BOOL destructive,
                       UIViewController *from, void (^handler)(void))
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = from;
        if (!top || top.presentedViewController) top = WQBTopViewController();
        if (!top) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:actionTitle
                                                  style:destructive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *__unused action) { handler(); }]];
        [top presentViewController:alert animated:YES completion:nil];
    });
}

static void WQBShareFile(NSString *path, UIViewController *from, void (^cleanup)(void))
{
    if (!path.length || !from) return;
    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                                                       applicationActivities:nil];
    share.completionWithItemsHandler = ^(UIActivityType __unused type, BOOL __unused completed,
                                         NSArray *__unused items, NSError *__unused error) {
        if (cleanup) cleanup();
    };
    if (share.popoverPresentationController) {
        share.popoverPresentationController.sourceView = from.view;
        share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(from.view.bounds),
                                                                    CGRectGetMidY(from.view.bounds), 1, 1);
    }
    [from presentViewController:share animated:YES completion:nil];
}

static NSString *WQBOffsetDescription(double seconds)
{
    if (seconds < 1) return @"不到 1 秒";
    if (seconds < 60) return [NSString stringWithFormat:@"约 %.0f 秒", seconds];
    if (seconds < 3600) return [NSString stringWithFormat:@"约 %.0f 分钟", seconds / 60.0];
    return [NSString stringWithFormat:@"约 %.1f 小时", seconds / 3600.0];
}

static BOOL WQBVerifyContentsSetting(void)
{
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:kWQBVerifyContentsKey];
    return stored ? [stored boolValue] : YES;
}


#pragma mark - App icons

@interface UIImage (WQBPrivateIcon)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(int)format scale:(CGFloat)scale;
@end

// A tiny fingerprint used to recognise iOS's blank placeholder icon.
static NSData *WQBIconFingerprint(UIImage *image)
{
    if (!image.CGImage) return nil;
    const size_t side = 12;
    uint8_t pixels[12 * 12 * 4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, side, side, 8, side * 4, space,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return nil;
    CGContextDrawImage(context, CGRectMake(0, 0, side, side), image.CGImage);
    CGContextRelease(context);
    return [NSData dataWithBytes:pixels length:sizeof(pixels)];
}

static UIImage *WQBPrivateIconRaw(NSString *bundleID)
{
    if (!bundleID.length) return nil;
    if (![UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) return nil;
    __block UIImage *image = nil;
    void (^load)(void) = ^{
        CGFloat scale = 2.0;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                scale = ((UIWindowScene *)scene).screen.scale;
                break;
            }
        }
        image = [UIImage _applicationIconImageForBundleIdentifier:bundleID format:2 scale:scale];
    };
    // UIKit's private icon call is a main-thread service. Warming happens on a
    // background queue, so hop over; the main thread never waits for icons.
    if (NSThread.isMainThread) load();
    else dispatch_sync(dispatch_get_main_queue(), load);
    return image.CGImage ? image : nil;
}

static UIImage *WQBPrivateIcon(NSString *bundleID)
{
    UIImage *raw = WQBPrivateIconRaw(bundleID);
    if (!raw) return nil;
    static NSData *placeholder;
    static NSObject *guard;
    static dispatch_once_t guardOnce;
    dispatch_once(&guardOnce, ^{ guard = [NSObject new]; });
    NSData *known;
    @synchronized (guard) { known = placeholder; }
    if (!known) {
        NSData *fresh = WQBIconFingerprint(WQBPrivateIconRaw(@"com.wqbackup.no-such-app"));
        @synchronized (guard) {
            if (!placeholder) placeholder = fresh;
            known = placeholder;
        }
    }
    NSData *fingerprint = WQBIconFingerprint(raw);
    if (!fingerprint.length || fingerprint.length != known.length) return raw;
    const uint8_t *a = fingerprint.bytes, *b = known.bytes;
    unsigned long difference = 0;
    for (NSUInteger i = 0; i < fingerprint.length; i++)
        difference += (unsigned long)abs((int)a[i] - (int)b[i]);
    return difference / fingerprint.length < 8 ? nil : raw;
}

static UIImage *WQBImageAtPath(NSString *path)
{
    if (!path.length) return nil;
    NSData *data = wq_read(path, 12 * 1024 * 1024, NULL);
    if (!data.length) return nil;
    UIImage *image = [UIImage imageWithData:data];
    return image.CGImage ? image : nil;
}

static NSArray<NSString *> *WQBInfoIconNames(NSDictionary *info)
{
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    for (NSString *key in @[@"CFBundleIcons", @"CFBundleIcons~ipad"]) {
        NSDictionary *icons = [info[key] isKindOfClass:NSDictionary.class] ? info[key] : nil;
        NSDictionary *primary = [icons[@"CFBundlePrimaryIcon"] isKindOfClass:NSDictionary.class] ? icons[@"CFBundlePrimaryIcon"] : nil;
        if (![primary isKindOfClass:NSDictionary.class]) continue;
        NSString *iconName = [primary[@"CFBundleIconName"] isKindOfClass:NSString.class] ? primary[@"CFBundleIconName"] : nil;
        if (iconName.length) [names addObject:iconName];
        NSArray *files = [primary[@"CFBundleIconFiles"] isKindOfClass:NSArray.class] ? primary[@"CFBundleIconFiles"] : @[];
        for (id file in files.reverseObjectEnumerator)
            if ([file isKindOfClass:NSString.class]) [names addObject:file];
    }
    if ([info[@"CFBundleIconFile"] isKindOfClass:NSString.class]) [names addObject:info[@"CFBundleIconFile"]];
    [names addObjectsFromArray:@[@"LCAppIconLight", @"LCAppIconDark", @"AppIcon60x60", @"AppIcon", @"Icon"]];
    return names;
}

// Reads a PNG next to the app's Info.plist (modern apps often only have
// Assets.car; LiveContainer additionally caches LCAppIconLight.png).
static UIImage *WQBBundleIcon(NSString *bundlePath)
{
    if (!bundlePath.length) return nil;
    wq_grant(bundlePath);
    NSDictionary *info = nil;
    NSData *plistData = wq_read([bundlePath stringByAppendingPathComponent:@"Info.plist"], 4 * 1024 * 1024, NULL);
    if (plistData.length) {
        id plist = [NSPropertyListSerialization propertyListWithData:plistData options:0 format:NULL error:nil];
        if ([plist isKindOfClass:NSDictionary.class]) info = plist;
    }
    NSArray<NSString *> *names = WQBInfoIconNames(info ?: @{});
    NSArray<NSString *> *suffixes = @[@"@3x.png", @"@2x.png", @"@2x~ipad.png", @"~ipad.png", @".png"];
    for (NSString *name in names) {
        NSString *base = [name stringByDeletingPathExtension];
        if (!base.length) continue;
        for (NSString *suffix in suffixes) {
            UIImage *image = WQBImageAtPath([bundlePath stringByAppendingPathComponent:[base stringByAppendingString:suffix]]);
            if (image) return image;
        }
    }
    return nil;
}

static NSString *WQBAppIconCacheKey(WQBAppTarget *target)
{
    if (target.kind == WQBBackupKindLocal)
        return [@"L/" stringByAppendingString:target.bundleID ?: @""];
    return [@"C/" stringByAppendingString:target.bundleID ?: target.key ?: @""];
}

@interface WQBAppIconStore : NSObject
+ (instancetype)shared;
- (nullable UIImage *)iconForKey:(NSString *)key;
- (void)warmTargets:(NSArray<WQBAppTarget *> *)targets;
@end

@implementation WQBAppIconStore {
    NSCache<NSString *, id> *_cache;
    dispatch_queue_t _queue;
}

+ (instancetype)shared
{
    static WQBAppIconStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [WQBAppIconStore new]; });
    return store;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _cache = [NSCache new];
        _cache.countLimit = 400;
        _queue = dispatch_queue_create("com.wqbackup.icons", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                                                      QOS_CLASS_UTILITY, 0));
    }
    return self;
}

- (UIImage *)iconForKey:(NSString *)key
{
    id value = [_cache objectForKey:key];
    return [value isKindOfClass:UIImage.class] ? value : nil;
}

- (UIImage *)loadIconForTarget:(WQBAppTarget *)target
{
    if (target.kind == WQBBackupKindLocal) {
        UIImage *icon = WQBPrivateIcon(target.bundleID);
        if (!icon) icon = WQBBundleIcon(target.bundlePath);
        if (!icon) {
            NSString *path = target.bundleID.length ? wq_bundle_path_for_id(target.bundleID) : nil;
            if (path.length && ![path isEqualToString:target.bundlePath]) icon = WQBBundleIcon(path);
        }
        return icon;
    }
    return WQBBundleIcon(target.lcAppFolder ?: target.bundlePath);
}

- (void)warmTargets:(NSArray<WQBAppTarget *> *)targets
{
    NSArray<WQBAppTarget *> *snapshot = [targets copy];
    dispatch_async(_queue, ^{
        BOOL changed = NO;
        for (WQBAppTarget *target in snapshot) {
            @autoreleasepool {
                NSString *key = WQBAppIconCacheKey(target);
                if ([self->_cache objectForKey:key]) continue;
                UIImage *icon = [self loadIconForTarget:target];
                [self->_cache setObject:(icon ?: (id)NSNull.null) forKey:key];
                if (icon) changed = YES;
            }
        }
        if (changed) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter postNotificationName:WQBAppIconsDidUpdateNotification
                                                                  object:nil];
            });
        }
    });
}

@end

#pragma mark - Overlay

@interface WQBOverlay : NSObject
+ (instancetype)shared;
- (void)showWithTitle:(NSString *)title status:(NSString *)status cancel:(void (^_Nullable)(void))cancel;
- (void)updateTitle:(NSString *)title status:(NSString *)status;
- (void)setStatus:(NSString *)status;
- (void)setProgress:(double)progress;
- (void)hide;
@end

@implementation WQBOverlay {
    UIView *_dim;
    UILabel *_titleLabel;
    UILabel *_statusLabel;
    UIActivityIndicatorView *_spinner;
    UIProgressView *_progressView;
    UIButton *_cancelButton;
    void (^_cancelBlock)(void);
    BOOL _visible;
}

+ (instancetype)shared
{
    static WQBOverlay *overlay;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ overlay = [WQBOverlay new]; });
    return overlay;
}

- (void)buildViewInWindow:(UIWindow *)window
{
    _dim = [[UIView alloc] initWithFrame:window.bounds];
    _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.32];
    _dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 18;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;
    [_dim addSubview:card];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [_spinner startAnimating];

    _titleLabel = [UILabel new];
    _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.numberOfLines = 2;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _statusLabel = [UILabel new];
    _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _statusLabel.textColor = UIColor.secondaryLabelColor;
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 3;
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progressView.translatesAutoresizingMaskIntoConstraints = NO;
    _progressView.hidden = YES;

    _cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_cancelButton setTitle:@"取消" forState:UIControlStateNormal];
    _cancelButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_cancelButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_spinner, _titleLabel, _statusLabel, _progressView, _cancelButton]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:_dim.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:_dim.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:300],
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-20],
        [_progressView.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
    ]];
}

- (void)showWithTitle:(NSString *)title status:(NSString *)status cancel:(void (^)(void))cancel
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_visible) {
            self->_cancelBlock = [cancel copy];
            [self updateTitleOnMain:title status:status];
            return;
        }
        UIWindow *window = WQBKeyWindow();
        if (!window) return;
        [self buildViewInWindow:window];
        self->_cancelBlock = [cancel copy];
        self->_titleLabel.text = title;
        self->_statusLabel.text = status;
        self->_cancelButton.hidden = (cancel == nil);
        self->_progressView.hidden = YES;
        [window addSubview:self->_dim];
        self->_visible = YES;
    });
}

- (void)updateTitleOnMain:(NSString *)title status:(NSString *)status
{
    if (title) _titleLabel.text = title;
    if (status) _statusLabel.text = status;
}

- (void)updateTitle:(NSString *)title status:(NSString *)status
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_visible) return;
        [self updateTitleOnMain:title status:status];
    });
}

- (void)setStatus:(NSString *)status
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_visible && status) self->_statusLabel.text = status;
    });
}

- (void)setProgress:(double)progress
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_visible) return;
        self->_progressView.hidden = NO;
        self->_spinner.hidden = YES;
        [self->_progressView setProgress:(float)MAX(0, MIN(1, progress)) animated:NO];
    });
}

- (void)cancelTapped
{
    void (^block)(void) = _cancelBlock;
    _cancelBlock = nil;
    _cancelButton.enabled = NO;
    [_cancelButton setTitle:@"正在取消…" forState:UIControlStateNormal];
    [self setStatus:@"正在取消，请稍候…"];
    if (block) block();
}

- (void)hide
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_visible) return;
        [self->_dim removeFromSuperview];
        self->_dim = nil;
        self->_visible = NO;
        self->_cancelBlock = nil;
        [self->_spinner stopAnimating];
    });
}

@end

#pragma mark - Full scan prompt

static BOOL gScanOverlayVisible;

BOOL WQBConfirmFullScan(NSString *what, int64_t ids, double seconds)
{
    if (NSThread.isMainThread) return NO;   // never scan unasked on the main thread
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    __block BOOL start = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = WQBTopViewController();
        if (!top) { dispatch_semaphore_signal(answered); return; }
        NSString *message = [NSString stringWithFormat:
            @"要列出 %@，需要先检查设备上的全部文件（约 %lld 个，预计 %@）。\n\n只需第一次扫描，之后会快很多。扫描期间请保持本软件在前台。",
            what, (long long)ids, WQBOffsetDescription(seconds)];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"需要扫描全部文件"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"暂不扫描" style:UIAlertActionStyleCancel
                                                handler:^(UIAlertAction *__unused action) {
            dispatch_semaphore_signal(answered);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"开始扫描" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *__unused action) {
            start = YES;
            gScanOverlayVisible = YES;
            [[WQBOverlay shared] showWithTitle:@"正在扫描全部文件" status:@"准备…" cancel:^{
                wq_full_scan_stop();
            }];
            dispatch_semaphore_signal(answered);
        }]];
        [top presentViewController:alert animated:YES completion:nil];
    });
    dispatch_semaphore_wait(answered, DISPATCH_TIME_FOREVER);
    return start;
}

void WQBFullScanProgress(int64_t done, int64_t total, BOOL finished)
{
    if (finished) {
        gScanOverlayVisible = NO;
        [[WQBOverlay shared] hide];
        return;
    }
    double fraction = total > 0 ? (double)done / (double)total : 0;
    [[WQBOverlay shared] setProgress:fraction];
    [[WQBOverlay shared] setStatus:[NSString stringWithFormat:@"%lld / %lld（%.0f%%）",
                                    (long long)done, (long long)total, fraction * 100]];
}

#pragma mark - State view

@interface WQBStateView : UIView
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation WQBStateView

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        _iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"tray"]];
        _iconView.tintColor = UIColor.tertiaryLabelColor;
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;

        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.hidesWhenStopped = YES;
        _spinner.translatesAutoresizingMaskIntoConstraints = NO;

        _label = [UILabel new];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.numberOfLines = 0;
        _label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        _label.textColor = UIColor.secondaryLabelColor;
        _label.translatesAutoresizingMaskIntoConstraints = NO;

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_iconView, _spinner, _label]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.spacing = 12;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-30],
            [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:32],
            [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-32],
            [_label.widthAnchor constraintLessThanOrEqualToConstant:320],
            [_iconView.widthAnchor constraintEqualToConstant:44],
            [_iconView.heightAnchor constraintEqualToConstant:44]
        ]];
    }
    return self;
}

@end

#pragma mark - Apps list

@interface WQBAppsViewController : UITableViewController <UISearchResultsUpdating>
- (instancetype)initWithKind:(WQBBackupKind)kind;
@end

@implementation WQBAppsViewController {
    WQBBackupKind _kind;
    NSArray<WQBAppTarget *> *_all;
    NSArray<NSArray<WQBAppTarget *> *> *_sections;
    NSArray<NSString *> *_sectionTitles;
    NSString *_note;
    NSString *_statusText;
    BOOL _loading;
    BOOL _loadedOnce;
    NSUInteger _loadGeneration;
    NSUInteger _originFilter;
    UIView *_filterHeader;
    UISegmentedControl *_originControl;
    WQBStateView *_stateView;
    NSMutableArray<WQBAppTarget *> *_allQueue;
    NSUInteger _allIndex;
    NSMutableArray<NSString *> *_allFailures;
    NSUInteger _allSuccess;
    BOOL _allCancelled;
    UIBackgroundTaskIdentifier _backgroundTask;
}

- (instancetype)initWithKind:(WQBBackupKind)kind
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _kind = kind;
        _backgroundTask = UIBackgroundTaskInvalid;
        self.title = kind == WQBBackupKindLiveContainer ? @"LiveContainer 应用" : @"本机应用";
        UIImage *icon = [UIImage systemImageNamed:kind == WQBBackupKindLiveContainer ? @"square.stack.3d.up" : @"iphone"];
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:kind == WQBBackupKindLiveContainer ? @"LiveContainer" : @"本机应用"
                                                        image:icon selectedImage:nil];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 74;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(userRefresh) forControlEvents:UIControlEventValueChanged];

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"搜索应用或 Bundle ID";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"全部备份"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self action:@selector(backupAllTapped)];
    self.navigationItem.rightBarButtonItem.enabled = NO;

    _stateView = [[WQBStateView alloc] initWithFrame:CGRectZero];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appIconsUpdated:)
                                                 name:WQBAppIconsDidUpdateNotification object:nil];
    if (_kind == WQBBackupKindLocal) {
        NSInteger stored = [NSUserDefaults.standardUserDefaults integerForKey:kWQBOriginFilterKey];
        _originFilter = (NSUInteger)MAX(0, MIN(2, stored));
        [self installOriginFilterHeader];
    }
    [self loadTargets];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)installOriginFilterHeader
{
    CGFloat width = self.tableView.bounds.size.width;
    _filterHeader = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 56)];
    _filterHeader.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _originControl = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"我的应用", @"系统应用"]];
    _originControl.selectedSegmentIndex = (NSInteger)_originFilter;
    _originControl.apportionsSegmentWidthsByContent = NO;
    [_originControl addTarget:self action:@selector(originFilterChanged:) forControlEvents:UIControlEventValueChanged];
    [_filterHeader addSubview:_originControl];
    self.tableView.tableHeaderView = _filterHeader;
    [self layoutOriginFilterHeader];
}

- (void)layoutOriginFilterHeader
{
    if (!_filterHeader) return;
    CGFloat width = self.tableView.bounds.size.width;
    CGFloat controlWidth = MIN(420.0, MAX(240.0, width - 40.0));
    _originControl.frame = CGRectMake((width - controlWidth) / 2.0, 8, controlWidth, 32);
    if (fabs(_filterHeader.frame.size.width - width) > 0.5) {
        _filterHeader.frame = CGRectMake(0, 0, width, 56);
        _filterHeader.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    }
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self layoutOriginFilterHeader];
}

- (void)originFilterChanged:(UISegmentedControl *)control
{
    _originFilter = (NSUInteger)MAX(0, control.selectedSegmentIndex);
    [NSUserDefaults.standardUserDefaults setInteger:(NSInteger)_originFilter forKey:kWQBOriginFilterKey];
    [self rebuildSections];
    [self.tableView reloadData];
    [self updateStateView];
}

- (void)appIconsUpdated:(NSNotification *)notification
{
    (void)notification;
    NSArray<NSIndexPath *> *visible = self.tableView.indexPathsForVisibleRows;
    if (visible.count) [self.tableView reloadRowsAtIndexPaths:visible withRowAnimation:UITableViewRowAnimationNone];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (!_loadedOnce) {
        if (!_loading) [self loadTargets];
        return;
    }
    if (!_all.count) return;
    for (WQBAppTarget *target in _all) [target reloadBackups];
    [[WQBAppIconStore shared] warmTargets:_all];
    [self rebuildSections];
    [self.tableView reloadData];
    [self updateAllButton];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    [self rebuildSections];
    [self.tableView reloadData];
    [self updateStateView];
}

- (void)userRefresh
{
    [WQBDiscovery invalidateCache];
    [self loadTargets];
}

- (void)loadTargets
{
    if (_loading) return;
    _loading = YES;
    _statusText = @"正在读取应用列表…";
    [self updateStateView];
    NSUInteger generation = ++_loadGeneration;
    WQBBackupKind kind = _kind;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *note = nil;
        NSArray<WQBAppTarget *> *apps = kind == WQBBackupKindLiveContainer
            ? [WQBDiscovery discoverLiveContainerAppsWithProgress:^(NSString *status) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) self = weakSelf;
                    if (!self || generation != self->_loadGeneration) return;
                    self->_statusText = status;
                    [self updateStateView];
                });
              } note:&note]
            : [WQBDiscovery discoverLocalAppsWithProgress:^(NSString *status) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) self = weakSelf;
                    if (!self || generation != self->_loadGeneration) return;
                    self->_statusText = status;
                    [self updateStateView];
                });
              } note:&note];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || generation != self->_loadGeneration) return;
            self->_all = apps;
            self->_note = note;
            self->_loading = NO;
            self->_loadedOnce = YES;
            [self.refreshControl endRefreshing];
            [self rebuildSections];
            [self.tableView reloadData];
            [self updateStateView];
            [self updateAllButton];
            if (kind == WQBBackupKindLiveContainer) {
                [NSUserDefaults.standardUserDefaults setInteger:(NSInteger)apps.count forKey:kWQBLastGuestCountKey];
            } else {
                NSUInteger system = 0, user = 0;
                for (WQBAppTarget *target in apps) {
                    if (target.origin == WQBAppOriginSystem) system++;
                    else if (target.origin == WQBAppOriginUser) user++;
                }
                [NSUserDefaults.standardUserDefaults setInteger:(NSInteger)system forKey:kWQBLastSystemCountKey];
                [NSUserDefaults.standardUserDefaults setInteger:(NSInteger)user forKey:kWQBLastUserCountKey];
                [NSUserDefaults.standardUserDefaults setInteger:(NSInteger)apps.count forKey:kWQBLastLocalCountKey];
            }
            [[WQBAppIconStore shared] warmTargets:apps];
            if (gScanOverlayVisible && !WQBBackupEngine.shared.busy) {
                gScanOverlayVisible = NO;
                [[WQBOverlay shared] hide];
            }
        });
    });
}

- (BOOL)hasRows
{
    for (NSArray *section in _sections) if (section.count) return YES;
    return NO;
}

- (void)updateStateView
{
    if (_loading) {
        _stateView.iconView.hidden = YES;
        [_stateView.spinner startAnimating];
        _stateView.label.text = _statusText ?: @"正在读取应用列表…";
        self.tableView.backgroundView = _stateView;
        return;
    }
    if ([self hasRows]) {
        self.tableView.backgroundView = nil;
        return;
    }
    _stateView.iconView.hidden = NO;
    [_stateView.spinner stopAnimating];
    NSString *empty = nil;
    if (_kind == WQBBackupKindLiveContainer)
        empty = @"这里只显示 LiveContainer 内的应用。\n如果还没安装 LiveContainer，请先安装并运行一个应用。";
    else if (_originFilter == 1)
        empty = @"“我的应用”里没有可备份的应用。";
    else if (_originFilter == 2)
        empty = @"“系统应用”里没有可备份的应用。";
    else
        empty = @"没有找到可备份的本机应用。";
    _stateView.label.text = _note.length ? [NSString stringWithFormat:@"%@\n\n%@", _note, empty] : empty;
    self.tableView.backgroundView = _stateView;
}

- (void)rebuildSections
{
    NSString *query = self.navigationItem.searchController.searchBar.text.lowercaseString;
    NSMutableArray<WQBAppTarget *> *filtered = [NSMutableArray new];
    for (WQBAppTarget *target in _all) {
        if (query.length) {
            NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@ %@", target.name, target.bundleID,
                                  target.lcContainerLabel ?: @"", target.lcOwnerName ?: @"",
                                  WQBOriginText(target.origin)].lowercaseString;
            if (![haystack containsString:query]) continue;
        }
        [filtered addObject:target];
    }
    if (_kind == WQBBackupKindLocal) {
        NSMutableArray<WQBAppTarget *> *userApps = [NSMutableArray new];
        NSMutableArray<WQBAppTarget *> *systemApps = [NSMutableArray new];
        for (WQBAppTarget *target in filtered) {
            if (_originFilter == 1 && target.origin == WQBAppOriginSystem) continue;
            if (_originFilter == 2 && target.origin != WQBAppOriginSystem) continue;
            if (target.origin == WQBAppOriginSystem) [systemApps addObject:target];
            else [userApps addObject:target];
        }
        NSMutableArray<NSArray<WQBAppTarget *> *> *sections = [NSMutableArray new];
        NSMutableArray<NSString *> *titles = [NSMutableArray new];
        if (userApps.count && _originFilter != 2) {
            [sections addObject:[userApps copy]];
            [titles addObject:[NSString stringWithFormat:@"我安装的应用（%lu）", (unsigned long)userApps.count]];
        }
        if (systemApps.count && _originFilter != 1) {
            [sections addObject:[systemApps copy]];
            [titles addObject:[NSString stringWithFormat:@"系统应用（%lu）", (unsigned long)systemApps.count]];
        }
        _sections = sections;
        _sectionTitles = titles;
        [self updateAllButton];
        return;
    }
    NSMutableArray<NSString *> *order = [NSMutableArray new];
    NSMutableDictionary<NSString *, NSMutableArray<WQBAppTarget *> *> *groups = [NSMutableDictionary new];
    for (WQBAppTarget *target in filtered) {
        NSString *key = target.lcOwnerName.length ? target.lcOwnerName : @"LiveContainer";
        if (!groups[key]) {
            groups[key] = [NSMutableArray new];
            [order addObject:key];
        }
        [groups[key] addObject:target];
    }
    NSMutableArray<NSArray<WQBAppTarget *> *> *sections = [NSMutableArray new];
    NSMutableArray<NSString *> *titles = [NSMutableArray new];
    for (NSString *key in order) {
        [sections addObject:[groups[key] copy]];
        if (order.count == 1) [titles addObject:@"LiveContainer 内的应用"];
        else [titles addObject:[key containsString:@"group."] ? [key stringByAppendingString:@"（共享容器）"] : key];
    }
    _sections = sections;
    _sectionTitles = titles;
    [self updateAllButton];
}

- (NSArray<WQBAppTarget *> *)displayedTargets
{
    NSMutableArray<WQBAppTarget *> *targets = [NSMutableArray new];
    for (NSArray<WQBAppTarget *> *section in _sections) [targets addObjectsFromArray:section];
    return targets;
}

- (void)updateAllButton
{
    BOOL any = NO;
    for (WQBAppTarget *target in [self displayedTargets]) if (target.available) { any = YES; break; }
    self.navigationItem.rightBarButtonItem.enabled = any && !WQBBackupEngine.shared.busy;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return (NSInteger)_sections.count; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section < (NSInteger)_sectionTitles.count ? _sectionTitles[section] : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (_kind != WQBBackupKindLocal) return nil;
    if (section != (NSInteger)_sections.count - 1) return nil;
    if (_originFilter == 1) return @"这些应用来自 App Store、AltStore、SideStore、TestFlight 等。";
    if (_originFilter == 2) return @"这些应用由 iOS 自带。";
    return @"“系统应用”由 iOS 自带；“我安装的应用”来自 App Store、AltStore、SideStore、TestFlight 等。";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section < (NSInteger)_sections.count ? (NSInteger)_sections[section].count : 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *identifier = @"AppCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    WQBAppTarget *target = _sections[indexPath.section][indexPath.row];
    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    content.text = target.name;
    content.secondaryText = [NSString stringWithFormat:@"%@\n%@", target.subtitleText, target.backupSummaryText];
    content.secondaryTextProperties.numberOfLines = 2;
    content.secondaryTextProperties.color = target.available ? UIColor.secondaryLabelColor : UIColor.tertiaryLabelColor;
    UIImage *appIcon = [[WQBAppIconStore shared] iconForKey:WQBAppIconCacheKey(target)];
    content.image = appIcon ?: [UIImage systemImageNamed:_kind == WQBBackupKindLiveContainer
                                                 ? @"square.stack.3d.up.fill" : @"app.dashed"];
    content.imageProperties.maximumSize = CGSizeMake(36, 36);
    content.imageProperties.reservedLayoutSize = CGSizeMake(36, 36);
    content.imageProperties.cornerRadius = 8;
    if (!appIcon) content.imageProperties.tintColor = target.available ? WQBAccentColor() : UIColor.tertiaryLabelColor;
    cell.contentConfiguration = content;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    WQBAppTarget *target = _sections[indexPath.section][indexPath.row];
    WQBAppDetailViewController *detail = [[WQBAppDetailViewController alloc] initWithTarget:target];
    [self.navigationController pushViewController:detail animated:YES];
}

#pragma mark All backups

- (void)backupAllTapped
{
    if (WQBBackupEngine.shared.busy) {
        WQBAlert(@"正在备份", @"请等待当前任务结束，或先取消。", self);
        return;
    }
    NSMutableArray<WQBAppTarget *> *available = [NSMutableArray new];
    for (WQBAppTarget *target in [self displayedTargets]) if (target.available) [available addObject:target];
    if (!available.count) {
        WQBAlert(@"没有可备份的应用", _note ?: @"当前列表为空。", self);
        return;
    }
    NSString *category = _kind == WQBBackupKindLiveContainer
        ? @" LiveContainer 数据容器"
        : (_originFilter == 1 ? @"“我的应用”" : (_originFilter == 2 ? @"“系统应用”" : @"本机应用"));
    NSString *message = [NSString stringWithFormat:
        @"将依次备份当前列表里的 %lu 个%@。\n\n应用正在运行时可能备份失败；建议先关闭要备份的应用。备份期间请保持本软件在前台。",
        (unsigned long)available.count, category];
    __weak typeof(self) weakSelf = self;
    WQBConfirm(@"全部备份", message, @"开始备份", NO, self, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self) [self runBackupAll:available];
    });
}

- (void)runBackupAll:(NSArray<WQBAppTarget *> *)targets
{
    _allQueue = [targets mutableCopy];
    _allIndex = 0;
    _allFailures = [NSMutableArray new];
    _allSuccess = 0;
    _allCancelled = NO;
    [self beginBackgroundWork];
    [self backupNext];
}

- (void)backupNext
{
    if (_allCancelled || _allIndex >= _allQueue.count) {
        [self finishBackupAll];
        return;
    }
    WQBAppTarget *target = _allQueue[_allIndex++];
    WQBBackupEngine *engine = WQBBackupEngine.shared;
    engine.verifyContents = WQBVerifyContentsSetting();
    WQBOverlay *overlay = [WQBOverlay shared];
    [overlay showWithTitle:[NSString stringWithFormat:@"全部备份 %lu/%lu", (unsigned long)_allIndex, (unsigned long)_allQueue.count]
                    status:[NSString stringWithFormat:@"正在备份 %@…", target.name]
                    cancel:^{ [engine cancel]; }];
    __weak typeof(self) weakSelf = self;
    [engine backupTarget:target progress:^(NSString *status) {
        [overlay setStatus:status];
    } completion:^(WQBBackupResult *result) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (result.success) {
            self->_allSuccess++;
        } else if ([result.errorText hasPrefix:@"已取消"]) {
            self->_allCancelled = YES;
        } else {
            [self->_allFailures addObject:[NSString stringWithFormat:@"%@：%@", target.name, result.errorText ?: @"失败"]];
        }
        [self backupNext];
    }];
}

- (void)finishBackupAll
{
    [[WQBOverlay shared] hide];
    [self endBackgroundWork];
    for (WQBAppTarget *target in _all) [target reloadBackups];
    [self rebuildSections];
    [self.tableView reloadData];
    [self updateAllButton];
    NSString *title = _allCancelled ? @"已取消全部备份" : @"全部备份完成";
    NSMutableString *message = [NSMutableString stringWithFormat:@"成功 %lu 个，失败 %lu 个。",
                                (unsigned long)_allSuccess, (unsigned long)_allFailures.count];
    if (_allFailures.count) {
        [message appendString:@"\n\n失败原因："];
        NSUInteger shown = MIN(_allFailures.count, (NSUInteger)8);
        for (NSUInteger i = 0; i < shown; i++) [message appendFormat:@"\n• %@", _allFailures[i]];
        if (_allFailures.count > shown) [message appendFormat:@"\n…另有 %lu 个", (unsigned long)(_allFailures.count - shown)];
    }
    UIViewController *presenter = self;
    WQBAlert(title, message, presenter);
    _allQueue = nil;
}

#pragma mark Background work

- (void)beginBackgroundWork
{
    UIApplication *app = UIApplication.sharedApplication;
    if (_backgroundTask == UIBackgroundTaskInvalid) {
        _backgroundTask = [app beginBackgroundTaskWithName:@"WQ Backup" expirationHandler:^{
            [app endBackgroundTask:self->_backgroundTask];
            self->_backgroundTask = UIBackgroundTaskInvalid;
        }];
    }
    app.idleTimerDisabled = YES;
}

- (void)endBackgroundWork
{
    UIApplication *app = UIApplication.sharedApplication;
    if (_backgroundTask != UIBackgroundTaskInvalid) {
        [app endBackgroundTask:_backgroundTask];
        _backgroundTask = UIBackgroundTaskInvalid;
    }
    app.idleTimerDisabled = NO;
}

@end

#pragma mark - App detail

@implementation WQBAppDetailViewController {
    WQBAppTarget *_target;
    NSArray<WQBBackupRecord *> *_records;
    NSArray<NSDictionary<NSString *, id> *> *_info;
    UIBackgroundTaskIdentifier _backgroundTask;
}

- (instancetype)initWithTarget:(WQBAppTarget *)target
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _target = target;
        _backgroundTask = UIBackgroundTaskInvalid;
        self.title = target.name;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 52;
    [self reloadRecords];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadRecords];
}

- (void)reloadRecords
{
    [_target reloadBackups];
    _records = _target.backups;
    NSMutableArray<NSDictionary<NSString *, id> *> *info = [NSMutableArray new];
    [info addObject:@{ @"title": @"应用名称", @"value": _target.name ?: @"" }];
    [info addObject:@{ @"title": @"Bundle ID", @"value": _target.bundleID ?: @"" }];
    [info addObject:@{ @"title": @"类型", @"value": _target.kind == WQBBackupKindLiveContainer
        ? @"LiveContainer 应用" : WQBOriginText(_target.origin) }];
    if (_target.kind == WQBBackupKindLiveContainer) {
        NSString *owner = _target.lcOwnerName.length ? _target.lcOwnerName : @"LiveContainer";
        NSString *container = _target.lcContainerLabel.length ? _target.lcContainerLabel : @"默认容器";
        [info addObject:@{ @"title": @"LiveContainer", @"value": owner }];
        [info addObject:@{ @"title": @"数据容器", @"value": [NSString stringWithFormat:@"%@（%@）", container,
                                                            _target.lcContainerFolder.length ? _target.lcContainerFolder : @"?"] }];
    }
    [info addObject:@{ @"title": @"数据位置（轻点复制）", @"value": _target.containerPath ?: @"", @"path": @YES }];
    if (_target.kind == WQBBackupKindLiveContainer && _target.lcAppFolder.length)
        [info addObject:@{ @"title": @"应用包（轻点复制）", @"value": _target.lcAppFolder, @"path": @YES }];
    else if (_target.bundlePath.length)
        [info addObject:@{ @"title": @"应用包（轻点复制）", @"value": _target.bundlePath, @"path": @YES }];
    [info addObject:@{ @"title": @"备份内容", @"value": @"Documents + Library（不包含 tmp 和系统数据）" }];
    if (_target.note.length) [info addObject:@{ @"title": @"说明", @"value": _target.note }];
    _info = info;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 1) return @"操作";
    if (section == 2) return [NSString stringWithFormat:@"备份记录（%lu）", (unsigned long)_records.count];
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 2 && !_records.count) return @"还没有备份。点上面的“立即备份”创建第一份。";
    if (section == 2) return @"轻点备份可恢复、校验、分享 ZIP 或删除。恢复会覆盖同名文件，不会删除备份里没有的文件。";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return (NSInteger)_info.count;
    if (section == 1) return 1;
    return (NSInteger)_records.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        static NSString *identifier = @"InfoCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
        NSDictionary *info = _info[indexPath.row];
        cell.textLabel.text = info[@"title"];
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.text = info[@"value"];
        cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        cell.detailTextLabel.textColor = UIColor.labelColor;
        cell.detailTextLabel.numberOfLines = 2;
        cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        cell.selectionStyle = info[@"path"] ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    if (indexPath.section == 1) {
        static NSString *identifier = @"ActionCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
        cell.textLabel.text = _target.available ? @"立即备份" : @"当前不可备份";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        cell.textLabel.textColor = _target.available ? WQBAccentColor() : UIColor.tertiaryLabelColor;
        cell.imageView.image = [UIImage systemImageNamed:@"arrow.up.doc.fill"];
        cell.imageView.tintColor = cell.textLabel.textColor;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    static NSString *identifier = @"RecordCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    WQBBackupRecord *record = _records[indexPath.row];
    cell.textLabel.text = record.dateText;
    cell.textLabel.textColor = record.complete ? UIColor.labelColor : UIColor.systemRedColor;
    cell.detailTextLabel.text = record.detailText;
    cell.detailTextLabel.numberOfLines = 2;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.imageView.image = [UIImage systemImageNamed:record.complete ? @"archivebox" : @"exclamationmark.triangle"];
    cell.imageView.tintColor = record.complete ? WQBAccentColor() : UIColor.systemRedColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        NSDictionary *info = _info[indexPath.row];
        if (![info[@"path"] boolValue]) return;
        UIPasteboard.generalPasteboard.string = info[@"value"];
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            cell.accessoryType = UITableViewCellAccessoryNone;
        });
        return;
    }
    if (indexPath.section == 1) {
        if (!_target.available) {
            WQBAlert(@"不可备份", _target.note ?: @"这个应用当前没有可用的数据容器。", self);
            return;
        }
        [self startBackup];
        return;
    }
    WQBBackupRecord *record = _records[indexPath.row];
    [self presentActionsForRecord:record indexPath:indexPath];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
        trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section != 2) return nil;
    WQBBackupRecord *record = _records[indexPath.row];
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIContextualAction *> *actions = [NSMutableArray new];
    if (record.complete) {
    UIContextualAction *share = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"分享"
                                                                      handler:^(UIContextualAction *__unused action,
                                                                                UIView *__unused view,
                                                                                void (^completion)(BOOL)) {
        completion(YES);
        __strong typeof(weakSelf) self = weakSelf;
        if (self) [self shareRecord:record];
    }];
    share.backgroundColor = WQBAccentColor();
    share.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
    [actions addObject:share];
    }
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除"
                                                                       handler:^(UIContextualAction *__unused action,
                                                                                 UIView *__unused view,
                                                                                 void (^completion)(BOOL)) {
        completion(YES);
        __strong typeof(weakSelf) self = weakSelf;
        if (self) [self confirmDeleteRecord:record];
    }];
    delete.image = [UIImage systemImageNamed:@"trash"];
    [actions addObject:delete];
    return [UISwipeActionsConfiguration configurationWithActions:actions];
}

- (void)presentActionsForRecord:(WQBBackupRecord *)record indexPath:(NSIndexPath *)indexPath
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:record.dateText
                                                                   message:record.detailText
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    if (record.complete) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"分享为 ZIP" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *__unused action) { [self shareRecord:record]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"恢复到应用" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *__unused action) { [self confirmRestoreRecord:record]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"校验备份" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *__unused action) { [self verifyRecord:record]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除备份" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *__unused action) { [self confirmDeleteRecord:record]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = cell ?: self.view;
        sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectMake(CGRectGetMidX(self.view.bounds),
                                                                                         CGRectGetMidY(self.view.bounds), 1, 1);
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)startBackup
{
    WQBBackupEngine *engine = WQBBackupEngine.shared;
    if (engine.busy) {
        WQBAlert(@"正在备份", @"请等待当前任务结束，或先取消。", self);
        return;
    }
    engine.verifyContents = WQBVerifyContentsSetting();
    [self beginBackgroundWork];
    WQBOverlay *overlay = [WQBOverlay shared];
    [overlay showWithTitle:[NSString stringWithFormat:@"正在备份 %@", _target.name]
                    status:@"准备…"
                    cancel:^{ [engine cancel]; }];
    __weak typeof(self) weakSelf = self;
    [engine backupTarget:_target progress:^(NSString *status) {
        [overlay setStatus:status];
    } completion:^(WQBBackupResult *result) {
        __strong typeof(weakSelf) self = weakSelf;
        [overlay hide];
        if (!self) return;
        [self endBackgroundWork];
        [self reloadRecords];
        if (result.success) {
            WQBAlert(@"备份完成", [NSString stringWithFormat:@"已保存 %@，共 %lu 个文件。",
                                   result.record.sizeText, (unsigned long)result.record.files], self);
        } else if (![result.errorText hasPrefix:@"已取消"]) {
            WQBAlert(@"备份失败", result.errorText ?: @"未知错误", self);
        }
    }];
}

- (void)confirmRestoreRecord:(WQBBackupRecord *)record
{
    NSString *message = [NSString stringWithFormat:
        @"将把这份备份覆盖到“%@”的同名文件中，不会删除备份里没有的文件。\n\n请先完全关闭“%@”，恢复完成后再重新打开。恢复过程中请不要离开本软件。",
        _target.name, _target.name];
    __weak typeof(self) weakSelf = self;
    WQBConfirm(@"恢复备份？", message, @"恢复", YES, self, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self) [self restoreRecord:record];
    });
}

- (void)restoreRecord:(WQBBackupRecord *)record
{
    WQBBackupEngine *engine = WQBBackupEngine.shared;
    if (engine.busy) {
        WQBAlert(@"正在备份", @"请等待当前任务结束，或先取消。", self);
        return;
    }
    [self beginBackgroundWork];
    WQBOverlay *overlay = [WQBOverlay shared];
    [overlay showWithTitle:[NSString stringWithFormat:@"正在恢复 %@", _target.name]
                    status:@"准备…"
                    cancel:^{ [engine cancel]; }];
    __weak typeof(self) weakSelf = self;
    [engine restoreBackup:record target:_target progress:^(NSString *status) {
        [overlay setStatus:status];
    } completion:^(WQBBackupResult *result) {
        __strong typeof(weakSelf) self = weakSelf;
        [overlay hide];
        if (!self) return;
        [self endBackgroundWork];
        [self reloadRecords];
        if (result.success) {
            WQBAlert(@"恢复完成", [NSString stringWithFormat:@"“%@”的数据已恢复。请重新打开这个应用。", self->_target.name], self);
        } else if (![result.errorText isEqualToString:@"已取消"]) {
            WQBAlert(@"恢复未完成", result.errorText ?: @"未知错误", self);
        }
    }];
}

- (void)verifyRecord:(WQBBackupRecord *)record
{
    WQBBackupEngine *engine = WQBBackupEngine.shared;
    if (engine.busy) {
        WQBAlert(@"正在备份", @"请等待当前任务结束，或先取消。", self);
        return;
    }
    WQBOverlay *overlay = [WQBOverlay shared];
    [overlay showWithTitle:@"正在校验备份" status:@"准备…" cancel:^{ [engine cancel]; }];
    __weak typeof(self) weakSelf = self;
    [engine verifyBackup:record progress:^(NSString *status) {
        [overlay setStatus:status];
    } completion:^(WQBBackupResult *result) {
        __strong typeof(weakSelf) self = weakSelf;
        [overlay hide];
        if (!self) return;
        if (result.success) WQBAlert(@"备份有效", @"文件数量与内容都和备份时一致。", self);
        else if (![result.errorText hasPrefix:@"已取消"]) WQBAlert(@"校验失败", result.errorText ?: @"未知错误", self);
    }];
}

- (void)shareRecord:(WQBBackupRecord *)record
{
    WQBBackupEngine *engine = WQBBackupEngine.shared;
    if (engine.busy) {
        WQBAlert(@"正在备份", @"请等待当前任务结束，或先取消。", self);
        return;
    }
    WQBOverlay *overlay = [WQBOverlay shared];
    [overlay showWithTitle:@"正在创建 ZIP" status:@"准备…" cancel:^{ [engine cancel]; }];
    __weak typeof(self) weakSelf = self;
    [engine exportZIPForBackup:record progress:^(NSString *status) {
        [overlay setStatus:status];
    } completion:^(NSString *zipPath, NSString *errorText) {
        __strong typeof(weakSelf) self = weakSelf;
        [overlay hide];
        if (!self) return;
        if (!zipPath.length) {
            if (![errorText hasPrefix:@"已取消"]) WQBAlert(@"打包失败", errorText ?: @"未知错误", self);
            return;
        }
        WQBShareFile(zipPath, self, ^{
            [NSFileManager.defaultManager removeItemAtPath:zipPath error:nil];
        });
    }];
}

- (void)confirmDeleteRecord:(WQBBackupRecord *)record
{
    __weak typeof(self) weakSelf = self;
    WQBConfirm(@"删除备份？", @"删除后无法恢复。其他备份不受影响。", @"删除", YES, self, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [[WQBBackupEngine shared] deleteBackup:record completion:^(BOOL ok, NSString *errorText) {
            if (ok) [self reloadRecords];
            else WQBAlert(@"删除失败", errorText ?: @"未知错误", self);
        }];
    });
}

- (void)beginBackgroundWork
{
    UIApplication *app = UIApplication.sharedApplication;
    if (_backgroundTask == UIBackgroundTaskInvalid) {
        _backgroundTask = [app beginBackgroundTaskWithName:@"WQ Backup" expirationHandler:^{
            [app endBackgroundTask:self->_backgroundTask];
            self->_backgroundTask = UIBackgroundTaskInvalid;
        }];
    }
    app.idleTimerDisabled = YES;
}

- (void)endBackgroundWork
{
    UIApplication *app = UIApplication.sharedApplication;
    if (_backgroundTask != UIBackgroundTaskInvalid) {
        [app endBackgroundTask:_backgroundTask];
        _backgroundTask = UIBackgroundTaskInvalid;
    }
    app.idleTimerDisabled = NO;
}

@end

#pragma mark - Log

@interface WQBLogViewController : UIViewController
@end

@implementation WQBLogViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"日志";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UITextView *textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    textView.editable = NO;
    textView.alwaysBounceVertical = YES;
    textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    textView.text = wq_log_text();
    textView.textContainerInset = UIEdgeInsetsMake(12, 12, 24, 12);
    [self.view addSubview:textView];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                                           target:self action:@selector(shareLog)];
}

- (void)shareLog
{
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"WQBackup-log.txt"];
    [[wq_log_text() dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];
    WQBShareFile(path, self, ^{
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    });
}

@end

#pragma mark - Settings

@interface WQBSettingsViewController : UITableViewController
@end

@implementation WQBSettingsViewController {
    NSString *_backupSizeText;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"设置";
    self.navigationItem.title = @"设置";
    [self refreshBackupSize];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)refreshBackupSize
{
    _backupSizeText = @"正在计算…";
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        unsigned long long bytes = 0;
        NSUInteger files = 0;
        BOOL ok = WQBTreeStats(WQBBackupRoot(), &bytes, &files, nil);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self->_backupSizeText = ok ? [NSString stringWithFormat:@"%@ · %lu 个文件",
                                          WQBFormatBytes(bytes), (unsigned long)files] : @"无法计算";
            if (self.isViewLoaded) [self.tableView reloadData];
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case 0: return @"运行状态";
        case 1: return @"备份";
        case 2: return @"维护";
        default: return @"关于";
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case 0: return 4;
        case 1: return 4;
        case 2: return 3;
        default: return 4;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *identifier = @"SettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.textLabel.textColor = UIColor.labelColor;

    if (indexPath.section == 0) {
        NSString *group = wq_app_group();
        if (indexPath.row == 0) {
            cell.textLabel.text = @"App Group";
            cell.detailTextLabel.text = group.length ? group : @"未获得。请用 AltStore、SideStore 或 Impactor 重新签名并保留 App Group。";
            cell.textLabel.textColor = group.length ? UIColor.labelColor : UIColor.systemRedColor;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"系统版本";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"iOS %@ · %@", UIDevice.currentDevice.systemVersion,
                                         wq_system_areas_reachable() ? @"完整访问范围" : @"受限访问范围（iOS 26）"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 2) {
            NSInteger local = [NSUserDefaults.standardUserDefaults integerForKey:kWQBLastLocalCountKey];
            NSInteger guest = [NSUserDefaults.standardUserDefaults integerForKey:kWQBLastGuestCountKey];
            cell.textLabel.text = @"已发现应用";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"本机 %ld 个 · LiveContainer %ld 个（以上次扫描为准）",
                                         (long)local, (long)guest];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            NSInteger system = [NSUserDefaults.standardUserDefaults integerForKey:kWQBLastSystemCountKey];
            NSInteger user = [NSUserDefaults.standardUserDefaults integerForKey:kWQBLastUserCountKey];
            cell.textLabel.text = @"本机应用分类";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"系统应用 %ld 个 · 我安装的应用 %ld 个",
                                         (long)system, (long)user];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        return cell;
    }
    if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"备份位置";
            cell.detailTextLabel.text = @"Documents/WQBackups（本软件“文件”共享里的 WQ 备份）";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"在“文件”中查看";
            cell.detailTextLabel.text = @"打开“文件”App → 我的 iPhone → WQ 备份 → WQBackups";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"备份后校验文件内容";
            cell.detailTextLabel.text = @"逐字节比较。更可靠，但大备份会更慢。";
            UISwitch *toggle = [UISwitch new];
            toggle.on = WQBVerifyContentsSetting();
            [toggle addTarget:self action:@selector(verifySwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.textLabel.text = @"备份占用";
            cell.detailTextLabel.text = _backupSizeText ?: @"正在计算…";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        return cell;
    }
    if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"重新扫描应用列表";
            cell.detailTextLabel.text = @"清除缓存；回到列表下拉刷新即可重新扫描。";
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"清理未完成的备份";
            cell.detailTextLabel.text = @"删除中断备份留下的暂存文件夹，不影响完整备份。";
        } else {
            cell.textLabel.text = @"查看日志";
            cell.detailTextLabel.text = @"访问令牌、扫描和备份的记录。";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        return cell;
    }
    if (indexPath.row == 0) {
        cell.textLabel.text = @"WQ Backup";
        cell.detailTextLabel.text = @"1.0 (1) · GPL-3.0-or-later";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.row == 1) {
        cell.textLabel.text = @"访问技术";
        cell.detailTextLabel.text = @"worse_query（WQ Files）· 无需越狱";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.row == 2) {
        cell.textLabel.text = @"LiveContainer";
        cell.detailTextLabel.text = @"数据容器、App Group 共享容器、多容器与旧版数据目录分开备份。";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text = @"限制";
        cell.detailTextLabel.text = @"iOS 27.3 beta 2 起 Apple 修补了 worse_query；需要保留 App Group 的签名工具。tmp 与 LiveContainer 外部数据文件夹无法备份。";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (void)verifySwitchChanged:(UISwitch *)toggle
{
    [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:kWQBVerifyContentsKey];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1 && indexPath.row == 1) {
        WQBAlert(@"在“文件”中查看", @"打开“文件”App，进入“我的 iPhone” → “WQ 备份” → “WQBackups”。\n\n本机应用备份在 Local 文件夹，LiveContainer 应用备份在 LiveContainer 文件夹。", self);
        return;
    }
    if (indexPath.section == 2 && indexPath.row == 0) {
        [WQBDiscovery invalidateCache];
        WQBAlert(@"已清除扫描缓存", @"回到“本机应用”或“LiveContainer”标签，下拉刷新即可重新扫描。", self);
        return;
    }
    if (indexPath.section == 2 && indexPath.row == 1) {
        [self cleanStagingFolders];
        return;
    }
    if (indexPath.section == 2 && indexPath.row == 2) {
        [self.navigationController pushViewController:[WQBLogViewController new] animated:YES];
    }
}

- (void)cleanStagingFolders
{
    NSUInteger removed = 0;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSNumber *kindNumber in @[@(WQBBackupKindLocal), @(WQBBackupKindLiveContainer)]) {
        WQBBackupKind kind = (WQBBackupKind)kindNumber.integerValue;
        NSString *root = WQBBackupRootForKind(kind);
        for (NSString *key in [fm contentsOfDirectoryAtPath:root error:nil]) {
            NSString *keyFolder = [root stringByAppendingPathComponent:key];
            for (NSString *name in [fm contentsOfDirectoryAtPath:keyFolder error:nil]) {
                if (![name hasPrefix:@".staging-"]) continue;
                if ([fm removeItemAtPath:[keyFolder stringByAppendingPathComponent:name] error:nil]) removed++;
            }
        }
    }
    [self refreshBackupSize];
    WQBAlert(@"已清理", [NSString stringWithFormat:@"删除了 %lu 个未完成的备份暂存文件夹。", (unsigned long)removed], self);
}

@end

#pragma mark - Root

@interface WQBRootTabBarController : UITabBarController
@end

@implementation WQBRootTabBarController

- (void)viewDidLoad
{
    [super viewDidLoad];
    WQBAppsViewController *local = [[WQBAppsViewController alloc] initWithKind:WQBBackupKindLocal];
    WQBAppsViewController *guest = [[WQBAppsViewController alloc] initWithKind:WQBBackupKindLiveContainer];
    WQBSettingsViewController *settings = [WQBSettingsViewController new];
    settings.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"设置" image:[UIImage systemImageNamed:@"gearshape"] selectedImage:nil];

    UINavigationController *localNav = [[UINavigationController alloc] initWithRootViewController:local];
    UINavigationController *guestNav = [[UINavigationController alloc] initWithRootViewController:guest];
    UINavigationController *settingsNav = [[UINavigationController alloc] initWithRootViewController:settings];
    localNav.navigationBar.prefersLargeTitles = YES;
    guestNav.navigationBar.prefersLargeTitles = YES;
    settingsNav.navigationBar.prefersLargeTitles = YES;
    self.viewControllers = @[localNav, guestNav, settingsNav];
}

@end

@implementation WQBSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions
{
    (void)session;
    (void)connectionOptions;
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [WQBRootTabBarController new];
    [self.window makeKeyAndVisible];
}

@end

@implementation WQBAppDelegate

- (UISceneConfiguration *)application:(UIApplication *)application
configurationForConnectingSceneSession:(UISceneSession *)session
                              options:(UISceneConnectionOptions *)options
{
    (void)application;
    (void)options;
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    configuration.delegateClass = WQBSceneDelegate.class;
    return configuration;
}

@end
