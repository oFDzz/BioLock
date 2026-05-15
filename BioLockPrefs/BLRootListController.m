#import "BLRootListController.h"
#import <objc/runtime.h>
#import <sys/stat.h>

#define kBLPrefsPath @"/var/jb/Library/Application Support/BioLock/prefs.plist"
#define kBLNotification "com.biolock.prefs/changed"

// LSApplicationWorkspace for enumerating installed apps
@interface LSApplicationProxy : NSObject
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
- (id)appState;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allInstalledApplications;
@end

@interface LSApplicationState : NSObject
- (BOOL)isValid;
@end

@implementation BLRootListController {
    NSMutableDictionary *_prefs;
    NSMutableSet *_lockedApps;
    NSArray<LSApplicationProxy *> *_apps;
    NSArray<LSApplicationProxy *> *_filteredApps;
    UISearchController *_searchController;
}

- (instancetype)init {
    if ((self = [super init])) {
        [self _loadPrefs];
        [self _loadApps];
    }
    return self;
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

    // chmod so SpringBoard can read it
    chmod([kBLPrefsPath UTF8String], 0666);
    chmod([dir UTF8String], 0755);

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(kBLNotification), NULL, NULL, YES);
}

- (void)_loadApps {
    Class LSW = NSClassFromString(@"LSApplicationWorkspace");
    NSArray<LSApplicationProxy *> *all =
        [[LSW performSelector:@selector(defaultWorkspace)]
              performSelector:@selector(allInstalledApplications)];

    NSMutableArray *userApps = [NSMutableArray new];
    for (LSApplicationProxy *proxy in all) {
        NSString *bid = [proxy applicationIdentifier];
        if (!bid) continue;
        // skip system/internal apps without UI
        if ([bid hasPrefix:@"com.apple.webapp"]) continue;
        if ([bid hasPrefix:@"com.apple.bridge"]) continue;
        // skip Settings itself
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

#pragma mark - View Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"BioLock";

    _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    _searchController.searchResultsUpdater = (id)self;
    _searchController.obscuresBackgroundDuringPresentation = NO;
    _searchController.searchBar.placeholder = @"Search apps...";
    self.navigationItem.searchController = _searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
}

#pragma mark - Table Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 3; // header, enable toggle, app list
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 0; // header
    if (section == 1) return 1; // enable toggle
    return _filteredApps.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return nil;
    if (section == 1) return @"GENERAL";
    return [NSString stringWithFormat:@"APPS (%lu locked)", (unsigned long)_lockedApps.count];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    if (section == 1)
        return @"When enabled, selected apps will require Face ID or passcode to open.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 1) {
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
    if (ip.section != 2) return;

    LSApplicationProxy *app = _filteredApps[ip.row];
    NSString *bid = [app applicationIdentifier];

    if ([_lockedApps containsObject:bid]) {
        [_lockedApps removeObject:bid];
    } else {
        [_lockedApps addObject:bid];
    }

    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    // update header to show new count
    [tv reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone];
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
    [self.table reloadData];
}

#pragma mark - PSListController (override to use custom table)

- (id)specifiers {
    return @[]; // we use raw table, not PSSpecifiers
}

- (UITableView *)table {
    return [super table];
}

@end
