// VCamPerAppViewController.m -- Installed-app allow-list
//
// App discovery is attempted three ways, in order, so the list is never empty:
//   1. LSApplicationWorkspace (private, fastest, gives display names + icons)
//   2. A scan of the on-disk bundle containers
//   3. A scan of /Applications (system + jailbreak apps)

#import "VCamPerAppViewController.h"
#import "../Shared/VCamConfig.h"
#import "../Shared/VCamTypes.h"
#import <objc/runtime.h>
#import <objc/message.h>

// -- Entry model ----------------------------------------------------------
@interface VCamAppEntry : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) UIImage *icon;
@end

@implementation VCamAppEntry
@end

// -- Discovery ------------------------------------------------------------
static NSArray<VCamAppEntry *> *vcam_discover_via_workspace(void) {
    Class wsClass = objc_getClass("LSApplicationWorkspace");
    if (!wsClass) return nil;

    id ws = ((id (*)(id, SEL))objc_msgSend)(wsClass,
                sel_registerName("defaultWorkspace"));
    if (!ws) return nil;

    SEL allSel = sel_registerName("allInstalledApplications");
    if (![ws respondsToSelector:allSel]) return nil;

    NSArray *proxies = ((id (*)(id, SEL))objc_msgSend)(ws, allSel);
    if (![proxies isKindOfClass:NSArray.class]) return nil;

    NSMutableArray<VCamAppEntry *> *out = [NSMutableArray array];

    for (id proxy in proxies) {
        @try {
            NSString *bid = nil;
            SEL bidSel = sel_registerName("applicationIdentifier");
            if ([proxy respondsToSelector:bidSel]) {
                bid = ((id (*)(id, SEL))objc_msgSend)(proxy, bidSel);
            }
            if (!bid.length) continue;

            // Skip Apple's internal/daemon bundles that have no UI.
            SEL typeSel = sel_registerName("applicationType");
            NSString *type = nil;
            if ([proxy respondsToSelector:typeSel]) {
                type = ((id (*)(id, SEL))objc_msgSend)(proxy, typeSel);
            }
            if ([type isEqualToString:@"Hidden"]) continue;

            NSString *name = nil;
            SEL nameSel = sel_registerName("localizedName");
            if ([proxy respondsToSelector:nameSel]) {
                name = ((id (*)(id, SEL))objc_msgSend)(proxy, nameSel);
            }

            VCamAppEntry *e = [VCamAppEntry new];
            e.bundleID = bid;
            e.name     = name.length ? name : bid;
            [out addObject:e];
        } @catch (NSException *ex) {
            continue;
        }
    }
    return out.count ? out : nil;
}

static void vcam_scan_directory(NSString *dir,
                                 NSMutableDictionary<NSString *, VCamAppEntry *> *into) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *children = [fm contentsOfDirectoryAtPath:dir error:nil];

    for (NSString *child in children) {
        NSString *path = [dir stringByAppendingPathComponent:child];

        // Two shapes: <dir>/Foo.app, or <dir>/<UUID>/Foo.app
        NSArray *candidates;
        if ([child hasSuffix:@".app"]) {
            candidates = @[path];
        } else {
            NSMutableArray *nested = [NSMutableArray array];
            for (NSString *g in [fm contentsOfDirectoryAtPath:path error:nil]) {
                if ([g hasSuffix:@".app"]) {
                    [nested addObject:[path stringByAppendingPathComponent:g]];
                }
            }
            candidates = nested;
        }

        for (NSString *appPath in candidates) {
            NSString *plist = [appPath stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
            NSString *bid = info[@"CFBundleIdentifier"];
            if (!bid.length || into[bid]) continue;

            // Needs a launchable UI to be worth listing.
            if (!info[@"CFBundleExecutable"]) continue;

            VCamAppEntry *e = [VCamAppEntry new];
            e.bundleID = bid;
            e.name     = info[@"CFBundleDisplayName"]
                          ?: info[@"CFBundleName"]
                          ?: bid;
            into[bid] = e;
        }
    }
}

static NSArray<VCamAppEntry *> *vcam_discover_apps(void) {
    NSArray *viaWorkspace = vcam_discover_via_workspace();
    if (viaWorkspace.count) {
        return [viaWorkspace sortedArrayUsingComparator:^NSComparisonResult(VCamAppEntry *a,
                                                                            VCamAppEntry *b) {
            return [a.name localizedCaseInsensitiveCompare:b.name];
        }];
    }

    VCamLogI("PerApp: LSApplicationWorkspace unavailable, scanning disk");

    NSMutableDictionary<NSString *, VCamAppEntry *> *found = [NSMutableDictionary dictionary];
    vcam_scan_directory(@"/var/containers/Bundle/Application", found);
    vcam_scan_directory(@"/private/var/containers/Bundle/Application", found);
    vcam_scan_directory(@"/Applications", found);

    return [found.allValues sortedArrayUsingComparator:^NSComparisonResult(VCamAppEntry *a,
                                                                           VCamAppEntry *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
}

// -- View controller ------------------------------------------------------
@interface VCamPerAppViewController () <UISearchBarDelegate>
@property (nonatomic, copy) NSArray<VCamAppEntry *> *allApps;
@property (nonatomic, copy) NSArray<VCamAppEntry *> *visibleApps;
@property (nonatomic, strong) UISearchBar *searchBar;
@end

@implementation VCamPerAppViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Enabled Apps";

    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.placeholder = @"Search apps";
    self.searchBar.delegate = self;
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    [self.searchBar sizeToFit];
    self.tableView.tableHeaderView = self.searchBar;

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [spinner startAnimating];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithCustomView:spinner];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *apps = vcam_discover_apps();
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.allApps     = apps;
            weakSelf.visibleApps = apps;
            weakSelf.navigationItem.rightBarButtonItem = nil;
            [weakSelf.tableView reloadData];
        });
    });
}

// -- Search --------------------------------------------------------------
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)text {
    if (!text.length) {
        self.visibleApps = self.allApps;
    } else {
        NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(VCamAppEntry *e, id b) {
            return [e.name localizedCaseInsensitiveContainsString:text]
                || [e.bundleID localizedCaseInsensitiveContainsString:text];
        }];
        self.visibleApps = [self.allApps filteredArrayUsingPredicate:p];
    }
    [self.tableView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

// -- Table ---------------------------------------------------------------
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.visibleApps.count;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (!self.allApps) return @"Loading installed apps…";
    return [NSString stringWithFormat:
            @"%lu apps found. Toggles here only take effect while Per-App Mode is on.",
            (unsigned long)self.allApps.count];
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    VCamAppEntry *e = self.visibleApps[ip.row];

    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"app"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                       reuseIdentifier:@"app"];
    }

    cell.textLabel.text       = e.name;
    cell.detailTextLabel.text = e.bundleID;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = [[VCamConfig shared].perAppList containsObject:e.bundleID];
    sw.tag = ip.row;
    [sw addTarget:self action:@selector(appToggled:)
        forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;

    return cell;
}

- (void)appToggled:(UISwitch *)sw {
    if (sw.tag >= (NSInteger)self.visibleApps.count) return;
    VCamAppEntry *e = self.visibleApps[sw.tag];
    [[VCamConfig shared] setApp:e.bundleID enabled:sw.isOn];
}

@end
