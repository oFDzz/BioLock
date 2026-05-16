#import "BLRootListController.h"
#import <objc/runtime.h>
#import <sys/stat.h>
#import <spawn.h>

#define kBLPrefsPath @"/var/jb/Library/Application Support/BioLock/prefs.plist"
#define kBLPrefsDir  @"/var/jb/Library/Application Support/BioLock"
#define kBLNotification "com.biolock.prefs/changed"

// ═════════════════════════════════════════════════════════════════
// Sections:
//   0 — Master toggle
//   1 — Protected apps (only locked ones, with swipe-to-remove)
//   2 — Stealth Mode settings
//   3 — Stealth hidden apps (only hidden ones, with swipe-to-remove)
//   4 — Add Apps (collapsible, searchable list of all unlocked apps)
// ═════════════════════════════════════════════════════════════════

typedef NS_ENUM(NSInteger, BLSection) {
    BLSectionToggle = 0,
    BLSectionProtected,
    BLSectionStealth,
    BLSectionStealthApps,
    BLSectionAddApps,
    BLSectionCount
};

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
    NSMutableSet *_stealthApps;
    NSArray<LSApplicationProxy *> *_allApps;
    NSArray<LSApplicationProxy *> *_unlockedApps;      // apps not yet locked (for "Add Apps")
    NSArray<LSApplicationProxy *> *_lockedAppsList;    // sorted list of locked apps
    NSArray<LSApplicationProxy *> *_stealthAppsList;   // sorted list of stealth apps
    NSArray<LSApplicationProxy *> *_filteredUnlocked;  // search-filtered
    UISearchController *_searchController;
    UIVisualEffectView *_authBlur;
    BOOL _authenticated;
    BOOL _authInProgress;
    BOOL _addAppsExpanded;
    BOOL _stealthAppsExpanded;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"BioLock";

    [self _loadPrefs];
    [self _loadApps];
    [self _rebuildLists];

    _addAppsExpanded = NO;
    _stealthAppsExpanded = NO;

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    [self.view addSubview:_tableView];

    // header
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 120)];

    UIImageView *shieldIcon = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"faceid" withConfiguration:
            [UIImageSymbolConfiguration configurationWithPointSize:36 weight:UIImageSymbolWeightMedium]]];
    shieldIcon.tintColor = [UIColor systemBlueColor];
    shieldIcon.frame = CGRectMake((header.bounds.size.width - 40) / 2, 16, 40, 40);
    [header addSubview:shieldIcon];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"BioLock";
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    title.frame = CGRectMake(0, 60, header.bounds.size.width, 34);
    [header addSubview:title];

    UILabel *sub = [[UILabel alloc] init];
    sub.text = @"App security & stealth protection";
    sub.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    sub.textColor = [UIColor secondaryLabelColor];
    sub.textAlignment = NSTextAlignmentCenter;
    sub.frame = CGRectMake(0, 94, header.bounds.size.width, 18);
    [header addSubview:sub];

    _tableView.tableHeaderView = header;

    // search — only active when add apps is expanded
    _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    _searchController.searchResultsUpdater = self;
    _searchController.obscuresBackgroundDuringPresentation = NO;
    _searchController.searchBar.placeholder = @"Search apps to add...";
    self.navigationItem.searchController = _searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;

    // ─── Auth gate ───
    _authenticated = NO;
    _authInProgress = NO;
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial];
    _authBlur = [[UIVisualEffectView alloc] initWithEffect:blur];
    _authBlur.frame = self.view.bounds;
    _authBlur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIImageView *lockIcon = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"lock.fill" withConfiguration:
            [UIImageSymbolConfiguration configurationWithPointSize:48 weight:UIImageSymbolWeightMedium]]];
    lockIcon.tintColor = [UIColor labelColor];
    lockIcon.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *lockLabel = [[UILabel alloc] init];
    lockLabel.text = @"Authenticate to access BioLock";
    lockLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    lockLabel.textColor = [UIColor secondaryLabelColor];
    lockLabel.textAlignment = NSTextAlignmentCenter;
    lockLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[lockIcon, lockLabel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    [_authBlur.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:_authBlur.contentView.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:_authBlur.contentView.centerYAnchor constant:-40]
    ]];

    [self.view addSubview:_authBlur];
    _tableView.userInteractionEnabled = NO;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!_authenticated) {
        [self _triggerAuth];
    }
}

#pragma mark - Authentication

- (void)_triggerAuth {
    if (_authInProgress) return;
    _authInProgress = YES;

    LAContext *ctx = [[LAContext alloc] init];
    ctx.localizedFallbackTitle = @"Enter Passcode";

    [ctx evaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
         localizedReason:@"Authenticate to access BioLock settings"
                   reply:^(BOOL success, NSError *error) {
        if (success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_authInProgress = NO;
                [self _authSucceeded];
            });
            return;
        }

        if (error.code == LAErrorUserFallback ||
            error.code == LAErrorBiometryLockout ||
            error.code == LAErrorAuthenticationFailed) {
            LAContext *ctx2 = [[LAContext alloc] init];
            [ctx2 evaluatePolicy:LAPolicyDeviceOwnerAuthentication
                  localizedReason:@"Authenticate to access BioLock settings"
                            reply:^(BOOL ok, NSError *err2) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_authInProgress = NO;
                    if (ok) [self _authSucceeded];
                    else [self _authFailed];
                });
            }];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_authInProgress = NO;
                [self _authFailed];
            });
        }
    }];
}

- (void)_authSucceeded {
    _authenticated = YES;
    [UIView animateWithDuration:0.3 animations:^{
        self->_authBlur.alpha = 0;
    } completion:^(BOOL finished) {
        [self->_authBlur removeFromSuperview];
        self->_tableView.userInteractionEnabled = YES;
    }];
}

- (void)_authFailed {
    if (self.navigationController)
        [self.navigationController popViewControllerAnimated:YES];
}

#pragma mark - Prefs I/O

- (void)_loadPrefs {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:kBLPrefsPath];
    _prefs = p ? [p mutableCopy] : [NSMutableDictionary new];
    NSArray *locked = _prefs[@"lockedApps"];
    _lockedApps = locked ? [NSMutableSet setWithArray:locked] : [NSMutableSet new];
    NSArray *stealth = _prefs[@"stealthHiddenApps"];
    _stealthApps = stealth ? [NSMutableSet setWithArray:stealth] : [NSMutableSet new];
}

- (void)_savePrefs {
    _prefs[@"lockedApps"] = [_lockedApps allObjects];
    _prefs[@"stealthHiddenApps"] = [_stealthApps allObjects];

    pid_t pid;
    extern char **environ;

    const char *args[] = {"/bin/mkdir", "-p", [kBLPrefsDir UTF8String], NULL};
    posix_spawn(&pid, "/bin/mkdir", NULL, NULL, (char **)args, environ);
    waitpid(pid, NULL, 0);

    const char *args2[] = {"/bin/chmod", "0777", [kBLPrefsDir UTF8String], NULL};
    posix_spawn(&pid, "/bin/chmod", NULL, NULL, (char **)args2, environ);
    waitpid(pid, NULL, 0);

    NSError *writeErr = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:_prefs
        format:NSPropertyListXMLFormat_v1_0 options:0 error:&writeErr];

    BOOL ok = NO;
    if (data) {
        ok = [data writeToFile:kBLPrefsPath options:NSDataWritingAtomic error:&writeErr];
    }

    if (ok) {
        chmod([kBLPrefsPath UTF8String], 0666);
    } else {
        NSLog(@"[BioLock-Prefs] ❌ save failed: %@", writeErr);
    }

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(kBLNotification), NULL, NULL, YES);
}

#pragma mark - App Lists

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

    _allApps = userApps;
}

- (void)_rebuildLists {
    NSMutableArray *locked = [NSMutableArray new];
    NSMutableArray *stealth = [NSMutableArray new];
    NSMutableArray *unlocked = [NSMutableArray new];

    for (LSApplicationProxy *app in _allApps) {
        NSString *bid = [app applicationIdentifier];
        if ([_lockedApps containsObject:bid]) {
            [locked addObject:app];
        } else {
            [unlocked addObject:app];
        }
        if ([_stealthApps containsObject:bid]) {
            [stealth addObject:app];
        }
    }

    _lockedAppsList = locked;
    _stealthAppsList = stealth;
    _unlockedApps = unlocked;
    _filteredUnlocked = unlocked;
}

- (LSApplicationProxy *)_proxyForBid:(NSString *)bid {
    for (LSApplicationProxy *app in _allApps) {
        if ([[app applicationIdentifier] isEqualToString:bid]) return app;
    }
    return nil;
}

- (UIImage *)_iconForBid:(NSString *)bid {
    UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:bid format:1 scale:[UIScreen mainScreen].scale];
    if (!icon) icon = [UIImage systemImageNamed:@"app.fill"];
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(32, 32), NO, 0);
    [icon drawInRect:CGRectMake(0, 0, 32, 32)];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

#pragma mark - UITableView DataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return BLSectionCount;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case BLSectionToggle: return 1;
        case BLSectionProtected: return _lockedAppsList.count > 0 ? _lockedAppsList.count : 0;
        case BLSectionStealth: return 2; // stealth enable + click count
        case BLSectionStealthApps: {
            if (!_stealthAppsExpanded) return _stealthAppsList.count > 0 ? 1 : 0; // "show" button or nothing
            return _stealthAppsList.count;
        }
        case BLSectionAddApps: {
            if (!_addAppsExpanded) return 1; // "Add Apps..." button
            return _filteredUnlocked.count + 1; // button + apps
        }
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case BLSectionToggle: return nil;
        case BLSectionProtected:
            return _lockedAppsList.count > 0 ?
                [NSString stringWithFormat:@"PROTECTED APPS (%lu)", (unsigned long)_lockedAppsList.count] : nil;
        case BLSectionStealth: return @"STEALTH MODE";
        case BLSectionStealthApps:
            return _stealthAppsList.count > 0 ?
                [NSString stringWithFormat:@"HIDDEN IN STEALTH (%lu)", (unsigned long)_stealthAppsList.count] : nil;
        case BLSectionAddApps: return @"APP LIBRARY";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case BLSectionToggle:
            return @"Apps require Face ID or device passcode. Protection covers home screen, app switcher, and notifications.";
        case BLSectionProtected:
            return _lockedAppsList.count > 0 ? @"Swipe left to remove protection." : nil;
        case BLSectionStealth:
            return @"Rapidly press the sleep button to toggle stealth mode. Hidden apps vanish from the home screen instantly.";
        case BLSectionStealthApps:
            return _stealthAppsList.count > 0 ? @"Swipe left to unhide." : nil;
        default: return nil;
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return 50;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    switch (ip.section) {
        case BLSectionToggle:
            return [self _toggleCellForTV:tv];
        case BLSectionProtected:
            return [self _protectedCellForTV:tv row:ip.row];
        case BLSectionStealth:
            return ip.row == 0 ? [self _stealthToggleCellForTV:tv] : [self _stealthClicksCellForTV:tv];
        case BLSectionStealthApps:
            if (!_stealthAppsExpanded && _stealthAppsList.count > 0)
                return [self _expandButtonCellForTV:tv title:@"Show Hidden Apps" expanded:NO tag:1];
            return [self _stealthAppCellForTV:tv row:ip.row];
        case BLSectionAddApps:
            if (ip.row == 0)
                return [self _expandButtonCellForTV:tv title:_addAppsExpanded ? @"Hide App Library" : @"Add Apps..." expanded:_addAppsExpanded tag:2];
            return [self _addAppCellForTV:tv row:ip.row - 1];
        default:
            return [[UITableViewCell alloc] init];
    }
}

#pragma mark - Cell Builders

- (UITableViewCell *)_toggleCellForTV:(UITableView *)tv {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"toggle"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"toggle"];
    cell.textLabel.text = @"Enable BioLock";
    cell.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    cell.imageView.image = [UIImage systemImageNamed:@"shield.checkered"];
    cell.imageView.tintColor = [UIColor systemBlueColor];
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = [_prefs[@"enabled"] boolValue];
    [sw addTarget:self action:@selector(_enableToggled:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UITableViewCell *)_protectedCellForTV:(UITableView *)tv row:(NSInteger)row {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"protected"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"protected"];

    LSApplicationProxy *app = _lockedAppsList[row];
    NSString *bid = [app applicationIdentifier];

    cell.textLabel.text = [app localizedName];
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    cell.detailTextLabel.text = bid;
    cell.detailTextLabel.textColor = [UIColor tertiaryLabelColor];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11];

    cell.imageView.image = [self _iconForBid:bid];
    cell.imageView.layer.cornerRadius = 7;
    cell.imageView.layer.masksToBounds = YES;

    UIImageView *lock = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"lock.fill"]];
    lock.tintColor = [UIColor systemGreenColor];
    lock.frame = CGRectMake(0, 0, 18, 18);
    cell.accessoryView = lock;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UITableViewCell *)_stealthToggleCellForTV:(UITableView *)tv {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"stealth_toggle"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"stealth_toggle"];
    cell.textLabel.text = @"Enable Stealth Mode";
    cell.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    cell.imageView.image = [UIImage systemImageNamed:@"eye.slash.fill"];
    cell.imageView.tintColor = [UIColor systemPurpleColor];
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = [_prefs[@"stealthEnabled"] boolValue];
    [sw addTarget:self action:@selector(_stealthToggled:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UITableViewCell *)_stealthClicksCellForTV:(UITableView *)tv {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"stealth_clicks"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"stealth_clicks"];
    cell.textLabel.text = @"Trigger Clicks";
    cell.textLabel.font = [UIFont systemFontOfSize:16];
    cell.imageView.image = [UIImage systemImageNamed:@"power"];
    cell.imageView.tintColor = [UIColor systemOrangeColor];

    NSInteger clicks = [_prefs[@"stealthClickCount"] integerValue];
    if (clicks < 3 || clicks > 6) clicks = 4;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld × Sleep", (long)clicks];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (UITableViewCell *)_stealthAppCellForTV:(UITableView *)tv row:(NSInteger)row {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"stealth_app"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"stealth_app"];

    LSApplicationProxy *app = _stealthAppsList[row];
    NSString *bid = [app applicationIdentifier];

    cell.textLabel.text = [app localizedName];
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    cell.detailTextLabel.text = @"Hidden in stealth";
    cell.detailTextLabel.textColor = [UIColor systemPurpleColor];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];

    cell.imageView.image = [self _iconForBid:bid];
    cell.imageView.layer.cornerRadius = 7;
    cell.imageView.layer.masksToBounds = YES;

    UIImageView *eye = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"eye.slash"]];
    eye.tintColor = [UIColor systemPurpleColor];
    eye.frame = CGRectMake(0, 0, 20, 16);
    cell.accessoryView = eye;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UITableViewCell *)_expandButtonCellForTV:(UITableView *)tv title:(NSString *)title expanded:(BOOL)expanded tag:(NSInteger)tag {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"expand"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"expand"];

    cell.textLabel.text = title;
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    cell.textLabel.textColor = [UIColor systemBlueColor];
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    cell.imageView.image = nil;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.tag = tag;
    return cell;
}

- (UITableViewCell *)_addAppCellForTV:(UITableView *)tv row:(NSInteger)row {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"add_app"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"add_app"];

    LSApplicationProxy *app = _filteredUnlocked[row];
    NSString *bid = [app applicationIdentifier];

    cell.textLabel.text = [app localizedName];
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.text = bid;
    cell.detailTextLabel.textColor = [UIColor tertiaryLabelColor];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11];

    cell.imageView.image = [self _iconForBid:bid];
    cell.imageView.layer.cornerRadius = 7;
    cell.imageView.layer.masksToBounds = YES;

    UIImageView *plus = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"plus.circle.fill"]];
    plus.tintColor = [UIColor systemBlueColor];
    plus.frame = CGRectMake(0, 0, 22, 22);
    cell.accessoryView = plus;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

#pragma mark - UITableView Delegate

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    switch (ip.section) {
        case BLSectionStealth: {
            if (ip.row == 1) [self _showClicksPicker];
            break;
        }
        case BLSectionStealthApps: {
            if (!_stealthAppsExpanded && _stealthAppsList.count > 0) {
                _stealthAppsExpanded = YES;
                [tv reloadSections:[NSIndexSet indexSetWithIndex:BLSectionStealthApps]
                    withRowAnimation:UITableViewRowAnimationAutomatic];
            }
            break;
        }
        case BLSectionAddApps: {
            if (ip.row == 0) {
                _addAppsExpanded = !_addAppsExpanded;
                [tv reloadSections:[NSIndexSet indexSetWithIndex:BLSectionAddApps]
                    withRowAnimation:UITableViewRowAnimationAutomatic];
            } else {
                [self _addAppAtFilteredRow:ip.row - 1];
            }
            break;
        }
        default: break;
    }
}

// swipe to delete for protected/stealth apps
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == BLSectionProtected) return YES;
    if (ip.section == BLSectionStealthApps && _stealthAppsExpanded) return YES;
    return NO;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    return UITableViewCellEditingStyleDelete;
}

- (NSString *)tableView:(UITableView *)tv titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == BLSectionProtected) return @"Unlock";
    return @"Unhide";
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete) return;

    if (ip.section == BLSectionProtected) {
        LSApplicationProxy *app = _lockedAppsList[ip.row];
        [_lockedApps removeObject:[app applicationIdentifier]];
    } else if (ip.section == BLSectionStealthApps) {
        LSApplicationProxy *app = _stealthAppsList[ip.row];
        [_stealthApps removeObject:[app applicationIdentifier]];
    }

    [self _savePrefs];
    [self _rebuildLists];
    [tv reloadData];
}

// long press on unlocked apps to add to stealth
- (UIContextMenuConfiguration *)tableView:(UITableView *)tv contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    if (ip.section == BLSectionAddApps && ip.row > 0) {
        LSApplicationProxy *app = _filteredUnlocked[ip.row - 1];
        NSString *bid = [app applicationIdentifier];
        NSString *name = [app localizedName];

        return [UIContextMenuConfiguration configurationWithIdentifier:nil
            previewProvider:nil
            actionProvider:^UIMenu * (NSArray<UIMenuElement *> *suggestedActions) {
                UIAction *lockAction = [UIAction actionWithTitle:@"Lock with Face ID"
                    image:[UIImage systemImageNamed:@"lock.fill"]
                    identifier:nil
                    handler:^(UIAction *action) {
                        [self->_lockedApps addObject:bid];
                        [self _savePrefs];
                        [self _rebuildLists];
                        [tv reloadData];
                    }];
                lockAction.accessibilityLabel = [NSString stringWithFormat:@"Lock %@", name];

                UIAction *stealthAction = [UIAction actionWithTitle:@"Hide in Stealth Mode"
                    image:[UIImage systemImageNamed:@"eye.slash.fill"]
                    identifier:nil
                    handler:^(UIAction *action) {
                        [self->_stealthApps addObject:bid];
                        [self _savePrefs];
                        [self _rebuildLists];
                        [tv reloadData];
                    }];

                UIAction *bothAction = [UIAction actionWithTitle:@"Lock + Hide in Stealth"
                    image:[UIImage systemImageNamed:@"shield.fill"]
                    identifier:nil
                    handler:^(UIAction *action) {
                        [self->_lockedApps addObject:bid];
                        [self->_stealthApps addObject:bid];
                        [self _savePrefs];
                        [self _rebuildLists];
                        [tv reloadData];
                    }];

                return [UIMenu menuWithTitle:name children:@[lockAction, stealthAction, bothAction]];
            }];
    }

    // context menu for protected apps to add stealth
    if (ip.section == BLSectionProtected) {
        LSApplicationProxy *app = _lockedAppsList[ip.row];
        NSString *bid = [app applicationIdentifier];
        BOOL alreadyStealth = [_stealthApps containsObject:bid];

        return [UIContextMenuConfiguration configurationWithIdentifier:nil
            previewProvider:nil
            actionProvider:^UIMenu * (NSArray<UIMenuElement *> *suggestedActions) {
                UIAction *action;
                if (alreadyStealth) {
                    action = [UIAction actionWithTitle:@"Remove from Stealth"
                        image:[UIImage systemImageNamed:@"eye.fill"]
                        identifier:nil
                        handler:^(UIAction *a) {
                            [self->_stealthApps removeObject:bid];
                            [self _savePrefs];
                            [self _rebuildLists];
                            [tv reloadData];
                        }];
                } else {
                    action = [UIAction actionWithTitle:@"Also Hide in Stealth"
                        image:[UIImage systemImageNamed:@"eye.slash.fill"]
                        identifier:nil
                        handler:^(UIAction *a) {
                            [self->_stealthApps addObject:bid];
                            [self _savePrefs];
                            [self _rebuildLists];
                            [tv reloadData];
                        }];
                }
                return [UIMenu menuWithTitle:@"" children:@[action]];
            }];
    }

    return nil;
}

#pragma mark - Actions

- (void)_enableToggled:(UISwitch *)sw {
    _prefs[@"enabled"] = @(sw.on);
    [self _savePrefs];
}

- (void)_stealthToggled:(UISwitch *)sw {
    _prefs[@"stealthEnabled"] = @(sw.on);
    [self _savePrefs];
}

- (void)_addAppAtFilteredRow:(NSInteger)row {
    if (row >= (NSInteger)_filteredUnlocked.count) return;
    LSApplicationProxy *app = _filteredUnlocked[row];
    NSString *bid = [app applicationIdentifier];
    [_lockedApps addObject:bid];
    [self _savePrefs];
    [self _rebuildLists];
    [_tableView reloadData];
}

- (void)_showClicksPicker {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Stealth Trigger"
        message:@"How many rapid sleep button presses to toggle stealth mode?"
        preferredStyle:UIAlertControllerStyleActionSheet];

    NSInteger current = [_prefs[@"stealthClickCount"] integerValue];
    if (current < 3 || current > 6) current = 4;

    for (NSInteger i = 3; i <= 6; i++) {
        NSString *title = [NSString stringWithFormat:@"%ld clicks%@", (long)i, i == current ? @" ✓" : @""];
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            self->_prefs[@"stealthClickCount"] = @(i);
            [self _savePrefs];
            [self->_tableView reloadSections:[NSIndexSet indexSetWithIndex:BLSectionStealth]
                withRowAnimation:UITableViewRowAnimationNone];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    NSString *q = sc.searchBar.text;
    if (!q.length) {
        _filteredUnlocked = _unlockedApps;
    } else {
        _filteredUnlocked = [_unlockedApps filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(LSApplicationProxy *app, NSDictionary *bindings) {
                return [[app localizedName] localizedCaseInsensitiveContainsString:q] ||
                       [[app applicationIdentifier] localizedCaseInsensitiveContainsString:q];
            }]];
    }
    [_tableView reloadSections:[NSIndexSet indexSetWithIndex:BLSectionAddApps]
        withRowAnimation:UITableViewRowAnimationNone];
}

@end
