#import "BLRootListController.h"
#import <objc/runtime.h>
#import <sys/stat.h>
#import <spawn.h>

#define kBLPrefsPath @"/var/jb/Library/Application Support/BioLock/prefs.plist"
#define kBLPrefsDir  @"/var/jb/Library/Application Support/BioLock"
#define kBLNotification "com.biolock.prefs/changed"

@interface LSApplicationProxy : NSObject
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
- (NSString *)bundleURL;
@end

@interface UIImage (Private)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)fmt scale:(CGFloat)scale;
@end

@implementation BLRootListController {
    NSMutableDictionary *_prefs;
    NSMutableSet *_lockedApps;
    NSArray<LSApplicationProxy *> *_apps;
    NSArray<LSApplicationProxy *> *_filteredApps;
    UISearchController *_searchController;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"BioLock";

    [self _loadPrefs];
    [self _loadApps];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    [self.view addSubview:_tableView];

    // header
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 130)];
    UILabel *title = [[UILabel alloc] init];
    title.text = @"BioLock";
    title.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    title.frame = CGRectMake(0, 20, header.bounds.size.width, 42);
    [header addSubview:title];

    UILabel *sub = [[UILabel alloc] init];
    sub.text = @"Lock apps with Face ID";
    sub.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    sub.textColor = [UIColor secondaryLabelColor];
    sub.textAlignment = NSTextAlignmentCenter;
    sub.frame = CGRectMake(0, 64, header.bounds.size.width, 20);
    [header addSubview:sub];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(40, 96, header.bounds.size.width - 80, 1)];
    line.backgroundColor = [UIColor separatorColor];
    [header addSubview:line];

    _tableView.tableHeaderView = header;

    // search
    _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    _searchController.searchResultsUpdater = self;
    _searchController.obscuresBackgroundDuringPresentation = NO;
    _searchController.searchBar.placeholder = @"Search apps...";
    self.navigationItem.searchController = _searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
}

#pragma mark - Prefs I/O

- (void)_loadPrefs {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:kBLPrefsPath];
    _prefs = p ? [p mutableCopy] : [NSMutableDictionary new];
    NSArray *locked = _prefs[@"lockedApps"];
    _lockedApps = locked ? [NSMutableSet setWithArray:locked] : [NSMutableSet new];
}

- (void)_savePrefs {
    _prefs[@"lockedApps"] = [_lockedApps allObjects];

    // ensure directory exists with proper perms
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:kBLPrefsDir isDirectory:&isDir] || !isDir) {
        // use posix_spawn for reliable directory creation on rootless
        const char *args[] = {"/bin/mkdir", "-p",
            [kBLPrefsDir UTF8String], NULL};
        pid_t pid;
        extern char **environ;
        posix_spawn(&pid, "/bin/mkdir", NULL, NULL, (char **)args, environ);
        waitpid(pid, NULL, 0);

        const char *args2[] = {"/bin/chmod", "0777",
            [kBLPrefsDir UTF8String], NULL};
        posix_spawn(&pid, "/bin/chmod", NULL, NULL, (char **)args2, environ);
        waitpid(pid, NULL, 0);
    }

    BOOL ok = [_prefs writeToFile:kBLPrefsPath atomically:YES];
    if (ok) {
        chmod([kBLPrefsPath UTF8String], 0666);
    } else {
        // fallback: try writing via posix_spawn
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:_prefs
            format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
        if (data) {
            [data writeToFile:kBLPrefsPath atomically:YES];
            chmod([kBLPrefsPath UTF8String], 0666);
        }
    }

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(kBLNotification), NULL, NULL, YES);
}

#pragma mark - App List

- (void)_loadApps {
    Class LSW = NSClassFromString(@"LSApplicationWorkspace");
    NSArray *all = [[LSW performSelector:@selector(defaultWorkspace)]
                         performSelector:@selector(allInstalledApplications)];

    NSMutableArray *userApps = [NSMutableArray new];
    for (LSApplicationProxy *proxy in all) {
        NSString *bid = [proxy applicationIdentifier];
        if (!bid) continue;
        if ([bid hasPrefix:@"com.apple.webapp"]) continue;
        if ([bid hasPrefix:@"com.apple.bridge"]) continue;
        if ([bid isEqualToString:@"com.apple.Preferences"]) continue;
        if ([bid isEqualToString:@"com.apple.springboard"]) continue;
        NSString *name = [proxy localizedName];
        if (!name.length) continue;
        [userApps addObject:proxy];
    }

    [userApps sortUsingComparator:^NSComparisonResult(LSApplicationProxy *a, LSApplicationProxy *b) {
        return [[a localizedName] localizedCaseInsensitiveCompare:[b localizedName]];
    }];

    _apps = userApps;
    _filteredApps = userApps;
}

- (UIImage *)_iconForBid:(NSString *)bid {
    UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:bid format:1 scale:[UIScreen mainScreen].scale];
    if (!icon) icon = [UIImage systemImageNamed:@"app.fill"];
    return icon;
}

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    return _filteredApps.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return nil;
    NSUInteger cnt = _lockedApps.count;
    return cnt > 0 ? [NSString stringWithFormat:@"%lu APP%@ LOCKED", (unsigned long)cnt, cnt == 1 ? @"" : @"S"]
                   : @"SELECT APPS TO LOCK";
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == 0)
        return @"Selected apps will require Face ID or your device passcode before opening.";
    return nil;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) return 50;
    return 56;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"toggle"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                  reuseIdentifier:@"toggle"];
        cell.textLabel.text = @"Enable BioLock";
        cell.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
        cell.imageView.image = [UIImage systemImageNamed:@"faceid"];
        cell.imageView.tintColor = [UIColor systemBlueColor];
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [_prefs[@"enabled"] boolValue];
        [sw addTarget:self action:@selector(_enableToggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"app"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                              reuseIdentifier:@"app"];

    LSApplicationProxy *app = _filteredApps[ip.row];
    NSString *bid = [app applicationIdentifier];
    BOOL locked = [_lockedApps containsObject:bid];

    cell.textLabel.text = [app localizedName];
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:locked ? UIFontWeightSemibold : UIFontWeightRegular];
    cell.detailTextLabel.text = locked ? @"Protected" : nil;
    cell.detailTextLabel.textColor = [UIColor systemGreenColor];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];

    // app icon (29x29)
    UIImage *icon = [self _iconForBid:bid];
    if (icon) {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(32, 32), NO, 0);
        [icon drawInRect:CGRectMake(0, 0, 32, 32)];
        cell.imageView.image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        cell.imageView.layer.cornerRadius = 7;
        cell.imageView.layer.masksToBounds = YES;
    }

    if (locked) {
        UIImageView *lock = [[UIImageView alloc] initWithImage:
            [UIImage systemImageNamed:@"lock.fill"]];
        lock.tintColor = [UIColor systemGreenColor];
        lock.frame = CGRectMake(0, 0, 18, 18);
        cell.accessoryView = lock;
    } else {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
    }

    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 1) return;

    LSApplicationProxy *app = _filteredApps[ip.row];
    NSString *bid = [app applicationIdentifier];

    if ([_lockedApps containsObject:bid]) {
        [_lockedApps removeObject:bid];
    } else {
        [_lockedApps addObject:bid];
    }

    [tv reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationAutomatic];
    [self _savePrefs];
}

- (void)_enableToggled:(UISwitch *)sw {
    _prefs[@"enabled"] = @(sw.on);
    [self _savePrefs];
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    NSString *q = sc.searchBar.text;
    if (!q.length) {
        _filteredApps = _apps;
    } else {
        _filteredApps = [_apps filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(LSApplicationProxy *app, NSDictionary *bindings) {
                return [[app localizedName] localizedCaseInsensitiveContainsString:q] ||
                       [[app applicationIdentifier] localizedCaseInsensitiveContainsString:q];
            }]];
    }
    [_tableView reloadData];
}

@end
