// BioLock — Lock apps with Face ID / passcode
// Runs only in SpringBoard. Hooks app icon taps, app switcher, and
// notification-based launches. Uses LAContext for biometric auth.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <objc/runtime.h>

#define kBLPrefsPlist @"/var/jb/Library/Application Support/BioLock/prefs.plist"
#define kBLNotification "com.biolock.prefs/changed"

// ═════════════════════════════════════════════════════════════════
// SpringBoard class forward declarations
// ═════════════════════════════════════════════════════════════════

@interface SBApplication : NSObject
- (NSString *)bundleIdentifier;
- (NSString *)displayName;
@end

@interface SBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (SBApplication *)applicationWithBundleIdentifier:(NSString *)bid;
@end

@interface SBIconView : UIView
- (SBApplication *)application;
@end

@interface SBMainSwitcherViewController : UIViewController
+ (instancetype)sharedInstance;
@end

@interface SBCoverSheetPresentationManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isPresented;
@end

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUILocked;
@end

// ═════════════════════════════════════════════════════════════════
// State
// ═════════════════════════════════════════════════════════════════

static BOOL sEnabled = NO;
static NSSet<NSString *> *sLockedApps = nil;
static NSMutableSet<NSString *> *sUnlockedThisSession = nil; // apps already authed since last lock
static BOOL sAuthInProgress = NO;

static void loadPrefs(void) {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:kBLPrefsPlist];
    sEnabled = [p[@"enabled"] boolValue];
    NSArray *apps = p[@"lockedApps"];
    sLockedApps = apps ? [NSSet setWithArray:apps] : [NSSet set];
}

static void onPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n,
                            const void *obj, CFDictionaryRef i) {
    loadPrefs();
}

static BOOL isAppLocked(NSString *bid) {
    if (!sEnabled || !bid || !sLockedApps.count) return NO;
    if (![sLockedApps containsObject:bid]) return NO;
    // already unlocked this session?
    if ([sUnlockedThisSession containsObject:bid]) return NO;
    return YES;
}

// ═════════════════════════════════════════════════════════════════
// Face ID / Passcode authentication
// ═════════════════════════════════════════════════════════════════

static void authenticateForApp(NSString *bid, NSString *appName,
                                void (^onSuccess)(void),
                                void (^onFail)(void)) {
    if (sAuthInProgress) return;
    sAuthInProgress = YES;

    LAContext *ctx = [[LAContext alloc] init];
    // show "Enter Passcode" button right away as fallback
    ctx.localizedFallbackTitle = @"Enter Passcode";

    NSString *reason = [NSString stringWithFormat:@"Unlock %@", appName ?: @"this app"];

    // first try biometrics (Face ID)
    [ctx evaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
         localizedReason:reason
                   reply:^(BOOL success, NSError *error) {
        if (success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                sAuthInProgress = NO;
                [sUnlockedThisSession addObject:bid];
                if (onSuccess) onSuccess();
            });
            return;
        }

        // biometrics failed — check why
        if (error.code == LAErrorUserFallback) {
            // user tapped "Enter Passcode" — use device passcode
            LAContext *ctx2 = [[LAContext alloc] init];
            [ctx2 evaluatePolicy:LAPolicyDeviceOwnerAuthentication
                  localizedReason:reason
                            reply:^(BOOL ok, NSError *err2) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    sAuthInProgress = NO;
                    if (ok) {
                        [sUnlockedThisSession addObject:bid];
                        if (onSuccess) onSuccess();
                    } else {
                        if (onFail) onFail();
                    }
                });
            }];
        } else if (error.code == LAErrorBiometryLockout ||
                   error.code == LAErrorBiometryNotEnrolled ||
                   error.code == LAErrorBiometryNotAvailable) {
            // biometrics unavailable — fall back to device passcode automatically
            LAContext *ctx3 = [[LAContext alloc] init];
            [ctx3 evaluatePolicy:LAPolicyDeviceOwnerAuthentication
                  localizedReason:reason
                            reply:^(BOOL ok, NSError *err3) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    sAuthInProgress = NO;
                    if (ok) {
                        [sUnlockedThisSession addObject:bid];
                        if (onSuccess) onSuccess();
                    } else {
                        if (onFail) onFail();
                    }
                });
            }];
        } else {
            // user cancelled or other error
            dispatch_async(dispatch_get_main_queue(), ^{
                sAuthInProgress = NO;
                if (onFail) onFail();
            });
        }
    }];
}

// ═════════════════════════════════════════════════════════════════
// Hook 1: Home screen icon tap
// ═════════════════════════════════════════════════════════════════

%hook SBIconView

- (void)setApplicationShortcutItems:(id)items {
    %orig;
}

// iOS 15: app launch via icon tap
- (void)_launchApp {
    SBApplication *app = [self application];
    if (!app) { %orig; return; }

    NSString *bid = [app bundleIdentifier];
    if (!isAppLocked(bid)) { %orig; return; }

    authenticateForApp(bid, [app displayName], ^{
        %orig;
    }, nil);
}

%end

// ═════════════════════════════════════════════════════════════════
// Hook 2: App switcher — returning to a locked app
// ═════════════════════════════════════════════════════════════════

%hook SBMainSwitcherViewController

- (void)_activateAppLayout:(id)layout {
    // try to extract bundle ID from the layout
    NSString *bid = nil;
    @try {
        // SBAppLayout -> displayItems -> first -> bundleIdentifier
        if ([layout respondsToSelector:@selector(allItems)]) {
            NSArray *items = [layout performSelector:@selector(allItems)];
            for (id item in items) {
                if ([item respondsToSelector:@selector(bundleIdentifier)]) {
                    bid = [item performSelector:@selector(bundleIdentifier)];
                    break;
                }
            }
        }
        if (!bid && [layout respondsToSelector:@selector(itemsToActivate)]) {
            NSArray *items = [layout performSelector:@selector(itemsToActivate)];
            for (id item in items) {
                if ([item respondsToSelector:@selector(bundleIdentifier)]) {
                    bid = [item performSelector:@selector(bundleIdentifier)];
                    break;
                }
            }
        }
    } @catch (NSException *e) {}

    if (!bid || !isAppLocked(bid)) { %orig; return; }

    SBApplication *app = [[%c(SBApplicationController) sharedInstance]
                          applicationWithBundleIdentifier:bid];
    authenticateForApp(bid, [app displayName], ^{
        %orig;
    }, nil);
}

%end

// ═════════════════════════════════════════════════════════════════
// Hook 3: Scene activation — catches ALL launch paths
// (notifications, Siri, URL schemes, Spotlight, etc.)
// ═════════════════════════════════════════════════════════════════

%hook SBMainWorkspace

- (void)applicationProcessWillLaunch:(id)process {
    %orig;
}

- (void)scene:(id)scene didReceiveActions:(id)actions {
    // try to get bundle ID from the scene
    NSString *bid = nil;
    @try {
        if ([scene respondsToSelector:@selector(clientProcess)]) {
            id proc = [scene performSelector:@selector(clientProcess)];
            if ([proc respondsToSelector:@selector(bundleIdentifier)])
                bid = [proc performSelector:@selector(bundleIdentifier)];
        }
        if (!bid && [scene respondsToSelector:@selector(specification)]) {
            id spec = [scene performSelector:@selector(specification)];
            if ([spec respondsToSelector:@selector(bundleIdentifier)])
                bid = [spec performSelector:@selector(bundleIdentifier)];
        }
    } @catch (NSException *e) {}

    // don't block scene updates for unlocked apps or if no bid found
    %orig;
}

%end

// ═════════════════════════════════════════════════════════════════
// Reset unlocked apps when device locks
// ═════════════════════════════════════════════════════════════════

%hook SBLockScreenManager

- (void)lockUIFromSource:(int)source withOptions:(id)options {
    %orig;
    // device locked — clear all session unlocks
    [sUnlockedThisSession removeAllObjects];
}

%end

// ═════════════════════════════════════════════════════════════════
// Constructor
// ═════════════════════════════════════════════════════════════════

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (![bid isEqualToString:@"com.apple.springboard"]) return;

        sUnlockedThisSession = [NSMutableSet new];
        loadPrefs();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, onPrefsChanged,
            CFSTR(kBLNotification), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        NSLog(@"[BioLock] ✅ loaded in SpringBoard — %lu apps locked",
              (unsigned long)sLockedApps.count);
    }
}
