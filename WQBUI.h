//
//  WQBUI.h
//  WQ Backup
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQBAppDelegate : UIResponder <UIApplicationDelegate>
@end

@interface WQBSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong, nullable) UIWindow *window;
@end

// Full-scan prompt and progress, installed with wq_set_full_scan_ui().
BOOL WQBConfirmFullScan(NSString *what, int64_t ids, double seconds);
void WQBFullScanProgress(int64_t done, int64_t total, BOOL finished);

NS_ASSUME_NONNULL_END
