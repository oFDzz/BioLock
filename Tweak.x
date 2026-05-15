// BioLock — Lock apps with Face ID / passcode
// Runs only in SpringBoard.

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

@interface SBIcon : NSObject
- (NSString *)applicationBundleID;
- (NSString *)displayName;
@end

@interface SBIconView : UIView
- (SBIcon *)icon;
@end

@interface SBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (SBApplication *)applicationWithBundleIdentifier:(NSString *)bid;
@end

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
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

// get bundle ID from SBIconView safely
static NSString *bundleIDFromIconView(id iconView) {
    @try {
        if ([iconView respondsToSelector:@selector(icon)]) {
            id icon = [iconView performSelector:@selector(icon)];
            if ([icon respondsToSelector:@selector(applicationBundleID)])
                return [icon performSelector:@selector(applicationBundleID)];
        }
        // fallback: try applicationBundleID directly on the view
        if ([iconView respondsToSelector:@selector(applicationBundleID)])
            return [iconView performSelector:@selector(applicationBundleID)];
    } @catch (NSException *e) {}
    return nil;
}

static NSString *displayNameFromIconView(id iconView) {
    @try {
        if ([iconView respondsToSelector:@selector(icon)]) {
            id icon = [iconView performSelector:@selector(icon)];
            if ([icon respondsToSelector:@selector(displayName)])
                return [icon performSelector:@selector(displayName)];
        }
    } @catch (NSException *e) {}
    return nil;
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
                        if (onFail) onFail();
                    }
                });
            }];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                sAuthInProgress = NO;
                NSLog(@"[BioLock] ❌ auth cancelled for %@ (code=%ld)", bid, (long)error.code);
                if (onFail) onFail();
            });
        }
    }];
}

// ═════════════════════════════════════════════════════════════════
// Runtime hook installer — finds and hooks the correct method
// ═════════════════════════════════════════════════════════════════

static IMP orig_iconViewLaunch = NULL;
static SEL hooked_launch_sel = NULL;

static void hooked_iconViewLaunch(id self, SEL _cmd) {
    NSString *bid = bundleIDFromIconView(self);
    NSLog(@"[BioLock] 📱 icon tap: %@ (sel=%s)", bid, sel_getName(_cmd));

    if (!bid || !isAppLocked(bid)) {
        ((void(*)(id, SEL))orig_iconViewLaunch)(self, _cmd);
        return;
    }

    NSString *name = displayNameFromIconView(self);
    authenticateForApp(bid, name, ^{
        ((void(*)(id, SEL))orig_iconViewLaunch)(self, hooked_launch_sel);
    }, nil);
}

static void installIconViewHook(void) {
    Class cls = objc_getClass("SBIconView");
    if (!cls) {
        NSLog(@"[BioLock] ⚠️ SBIconView class not found!");
        return;
    }

    // try these selectors in order — first one that exists wins
    const char *candidates[] = {
        "_launchApp",
        "launchApp",
        "_handleSecondHalfTap",
        "_didTap",
        "_handleTap",
        "activateShortcut:withBundleIdentifier:forIconView:",
        NULL
    };

    // first dump ALL methods with launch/tap/activate for diagnostics
    unsigned int mc = 0;
    Method *methods = class_copyMethodList(cls, &mc);
    NSLog(@"[BioLock] SBIconView: %u methods total. Candidates:", mc);
    for (unsigned int i = 0; i < mc; i++) {
        const char *sel = sel_getName(method_getName(methods[i]));
        if (strstr(sel, "launch") || strstr(sel, "Launch") ||
            strstr(sel, "activate") || strstr(sel, "Activate") ||
            strstr(sel, "tap") || strstr(sel, "Tap") ||
            strstr(sel, "open") || strstr(sel, "Open") ||
            strstr(sel, "action") || strstr(sel, "Action") ||
            strstr(sel, "touch") || strstr(sel, "Touch")) {
            NSLog(@"[BioLock] 📋 -> %s", sel);
        }
    }
    if (methods) free(methods);

    // try hooking each candidate
    for (int i = 0; candidates[i]; i++) {
        SEL sel = sel_registerName(candidates[i]);
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            orig_iconViewLaunch = method_getImplementation(m);
            hooked_launch_sel = sel;
            method_setImplementation(m, (IMP)hooked_iconViewLaunch);
            NSLog(@"[BioLock] ✅ hooked SBIconView -> %s", candidates[i]);
            return;
        }
    }

    NSLog(@"[BioLock] ⚠️ no known launch method found on SBIconView!");
}

// ═════════════════════════════════════════════════════════════════
// Reset unlocked apps when device locks
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

        // install hooks via runtime (finds correct method for this iOS version)
        installIconViewHook();

        NSLog(@"[BioLock] ✅ loaded in SpringBoard — %lu apps locked",
              (unsigned long)sLockedApps.count);
    }
}
