//
//  main.m
//  WQ Backup
//
//  GPL-3.0-or-later. Sandbox access: worse_query by Taj C (forcequitOS);
//  access/backup helpers derived from WQ Files by kolbicz.
//

#import <UIKit/UIKit.h>
#import "WQBUI.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import "WQScanJournal.h"

int main(int argc, char *argv[])
{
    @autoreleasepool {
        // Same wiring as WQ Files: label containers from the container manager
        // and the LaunchServices database when the identifier attribute can't
        // be read, and fall back to that database on iOS 26.
        wq_set_container_label_resolver(wq_bundle_id_for_container);
        wq_set_group_label_resolver(wq_group_id_for_container);
        wq_set_container_list_provider(wq_ls_container_paths);
        wq_set_full_scan_ui(WQBConfirmFullScan, WQBFullScanProgress);
        WQScanJournalPrune(7 * 86400);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(WQBAppDelegate.class));
    }
}
