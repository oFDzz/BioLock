#import "BLRootListController.h"
#import <objc/runtime.h>
#import <sys/stat.h>

#define kBLPrefsPath @"/var/jb/Library/Application Support/BioLock/prefs.plist"
#define kBLNotification "com.biolock.prefs/changed"

@interface LSApplicationProxy : NSObject
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
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

    _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    _searchController.searchResultsUpdater = self;
    _searchController.obscuresBackgroundDuringPresentation = NO;
    _searchController.searchBar.placeholder = @"Search apps...";
    self.navigationItem.searchController = _searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
}

- (void)_loadPrefs {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:kBLPrefsPath];
    _prefs = p ? [p mutableCopy] : [NSMutableDictionary new];
    NSArray *locked = _prefs[@"lockedApps"];
    _lockedApps = locked ? [NSMutableSet setWithArray:locked] : [NSMutableSet new];
}

- (void)_savePrefs {
    _prefs[@"lockedApps"] = [_lockedApps allObjects];

    NSString *dir = [kBLPrefsPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
        withIntermediateDirectories:YES attributes:nil error:nil];
    [_prefs writeToFile:kBLPrefsPath atomically:YES];

    chmod([kBLPrefsPath UTF8String], 0666);
    chmod([dir UTF8String], 0755);

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(kBLNotification), NULL, NULL, YES);
}

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

#pragma mark - UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 2; // enable toggle, app list
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    return _filteredApps.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"GENERAL";
    return [NSString stringWithFormat:@"APPS (%lu locked)", (unsigned long)_lockedApps.count];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == 0)
        return @"When enabled, selected apps will require Face ID or passcode to open.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"toggle"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                  reuseIdentifier:@"toggle"];
        cell.textLabel.text = @"Enable BioLock";
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
    cell.textLabel.text = [app localizedName];
    cell.detailTextLabel.text = bid;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.accessoryType = [_lockedApps containsObject:bid]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.tintColor = [UIColor systemBlueColor];
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

    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    [tv reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
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
