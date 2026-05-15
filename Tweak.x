// BioLock — Lock apps with Face ID / passcode
// Runs only in SpringBoard. Hooks app icon taps and app switcher.
// Uses LAContext for biometric auth with passcode fallback.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <objc/runtime.h>

#define kBLPrefsPlist @"/var/jb/Library/Application Support/BioLock/prefs.plist"
#define kBLNotification "com.biolock.prefs/changed"

// ═════════════════════════════════════════════════════════════════
// SpringBoard class declarations
// ═════════════════════════════════════════════════════════════════

@interface SBApplication : NSObject
- (NSString *)bundleIdentifier;
- (NSString *)displayName;
@end

@interface SBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (SBApplication *)applicationWithBundleIdentifier:(NSString *)bid;
@end

@interface SBIcon : NSObject
- (NSString *)applicationBundleID;
- (NSString *)displayName;
@end

@interface SBIconView : UIView
- (SBIcon *)icon;
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
static NSMutableSet<NSString *> *sUnlockedThisSession = nil;
static BOOL sAuthInProgress = NO;

static void loadPrefs(void) {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:kBLPrefsPlist];
    sEnabled = [p[@"enabled"] boolValue];
    NSArray *apps = p[@"lockedApps"];
    sLockedApps = apps ? [NSSet setWithArray:apps] : [NSSet set];
    NSLog(@"[BioLock] prefs loaded: enabled=%d locked=%lu apps: %@",
          sEnabled, (unsigned long)sLockedApps.count, sLockedApps);
}

static void onPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n,
                            const void *obj, CFDictionaryRef i) {
    loadPrefs();
}

static BOOL isAppLocked(NSString *bid) {
    if (!sEnabled || !bid || !sLockedApps.count) return NO;
    if (![sLockedApps containsObject:bid]) return NO;
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

    NSLog(@"[BioLock] 🔐 authenticating for %@ (%@)", appName, bid);

    LAContext *ctx = [[LAContext alloc] init];
    ctx.localizedFallbackTitle = @"Enter Passcode";

    NSError *canEvalErr = nil;
    BOOL canBio = [ctx canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
                                   error:&canEvalErr];

    // pick policy: biometrics if available, otherwise device passcode
    LAPolicy policy = canBio
        ? LAPolicyDeviceOwnerAuthenticationWithBiometrics
        : LAPolicyDeviceOwnerAuthentication;

    NSString *reason = [NSString stringWithFormat:@"Unlock %@", appName ?: @"this app"];

    [ctx evaluatePolicy:policy localizedReason:reason
                  reply:^(BOOL success, NSError *error) {
        if (success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                sAuthInProgress = NO;
                [sUnlockedThisSession addObject:bid];
                NSLog(@"[BioLock] ✅ authenticated for %@", bid);
                if (onSuccess) onSuccess();
            });
            return;
        }

        // user tapped "Enter Passcode" fallback
        if (error.code == LAErrorUserFallback) {
            LAContext *ctx2 = [[LAContext alloc] init];
            [ctx2 evaluatePolicy:LAPolicyDeviceOwnerAuthentication
                  localizedReason:reason
                            reply:^(BOOL ok, NSError *err2) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    sAuthInProgress = NO;
                    if (ok) {
                        [sUnlockedThisSession addObject:bid];
                        NSLog(@"[BioLock] ✅ passcode auth for %@", bid);
                        if (onSuccess) onSuccess();
                    } else {
                        NSLog(@"[BioLock] ❌ passcode failed for %@", bid);
                        if (onFail) onFail();
                    }
                });
            }];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                sAuthInProgress = NO;
                NSLog(@"[BioLock] ❌ auth failed/cancelled for %@ (code=%ld)", bid, (long)error.code);
                if (onFail) onFail();
            });
        }
    }];
}

// ═════════════════════════════════════════════════════════════════
// Hook 1: Home screen icon tap
// SBIconView handles icon taps. On iOS 15 the method chain is:
// tap gesture → _handleTap → _launchApp / _activateApp etc.
// We hook multiple potential entry points.
// ═════════════════════════════════════════════════════════════════

%hook SBIconView

- (void)_launchApp {
    NSString *bid = nil;
    @try {
        SBIcon *icon = [self icon];
        if ([icon respondsToSelector:@selector(applicationBundleID)])
            bid = [icon applicationBundleID];
    } @catch (NSException *e) {}
    NSLog(@"[BioLock] 📱 _launchApp: %@", bid);
    if (!bid || !isAppLocked(bid)) { %orig; return; }

    NSString *name = nil;
    @try { name = [[self icon] displayName]; } @catch (NSException *e) {}
    authenticateForApp(bid, name, ^{ %orig; }, nil);
}

%end

// ═════════════════════════════════════════════════════════════════
// Hook 2: Reset unlocked apps when device locks
// ═════════════════════════════════════════════════════════════════

%hook SBLockScreenManager

- (void)lockUIFromSource:(int)source withOptions:(id)options {
    %orig;
    NSLog(@"[BioLock] 🔒 device locked — clearing session");
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
