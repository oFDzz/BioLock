// BioLock — Lock apps with Face ID / passcode
// Runs only in SpringBoard. Hooks SBIconView._handleTap.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <objc/runtime.h>

#define kBLPrefsPlist @"/var/jb/Library/Application Support/BioLock/prefs.plist"
#define kBLNotification "com.biolock.prefs/changed"

@interface SBIcon : NSObject
- (NSString *)applicationBundleID;
- (NSString *)displayName;
@end

@interface SBIconView : UIView
- (SBIcon *)icon;
@end

// ═════════════════════════════════════════════════════════════════
// State
// ═════════════════════════════════════════════════════════════════

static BOOL sEnabled = NO;
static NSSet<NSString *> *sLockedApps = nil;
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
    return [sLockedApps containsObject:bid];
}

static NSString *bidFromIconView(id iv) {
    @try {
        SBIcon *icon = [iv performSelector:@selector(icon)];
        if ([icon respondsToSelector:@selector(applicationBundleID)])
            return [icon applicationBundleID];
    } @catch (NSException *e) {}
    return nil;
}

static NSString *nameFromIconView(id iv) {
    @try {
        SBIcon *icon = [iv performSelector:@selector(icon)];
        if ([icon respondsToSelector:@selector(displayName)])
            return [icon displayName];
    } @catch (NSException *e) {}
    return nil;
}

// ═════════════════════════════════════════════════════════════════
// Authentication — Face ID with visible passcode fallback button
// ═════════════════════════════════════════════════════════════════

static void authenticateForApp(NSString *bid, NSString *appName,
                                void (^onSuccess)(void)) {
    if (sAuthInProgress) return;
    sAuthInProgress = YES;

    LAContext *ctx = [[LAContext alloc] init];
    // this text appears as a button during Face ID scan
    ctx.localizedFallbackTitle = @"Enter Passcode";

    NSString *reason = [NSString stringWithFormat:@"Unlock %@", appName ?: @"this app"];

    // start with biometrics — shows Face ID with "Enter Passcode" button visible
    [ctx evaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
         localizedReason:reason
                   reply:^(BOOL success, NSError *error) {
        if (success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                sAuthInProgress = NO;
                if (onSuccess) onSuccess();
            });
            return;
        }

        // user tapped "Enter Passcode" or Face ID failed/locked out
        if (error.code == LAErrorUserFallback ||
            error.code == LAErrorBiometryLockout ||
            error.code == LAErrorAuthenticationFailed) {
            // show device passcode input
            LAContext *ctx2 = [[LAContext alloc] init];
            [ctx2 evaluatePolicy:LAPolicyDeviceOwnerAuthentication
                  localizedReason:reason
                            reply:^(BOOL ok, NSError *err2) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    sAuthInProgress = NO;
                    if (ok && onSuccess) onSuccess();
                });
            }];
        } else {
            // user cancelled
            dispatch_async(dispatch_get_main_queue(), ^{
                sAuthInProgress = NO;
            });
        }
    }];
}

// ═════════════════════════════════════════════════════════════════
// Hook: SBIconView._handleTap (iOS 15)
// ═════════════════════════════════════════════════════════════════

static IMP orig_handleTap = NULL;

static void hooked_handleTap(id self, SEL _cmd) {
    NSString *bid = bidFromIconView(self);

    if (!bid || !isAppLocked(bid)) {
        ((void(*)(id, SEL))orig_handleTap)(self, _cmd);
        return;
    }

    NSString *name = nameFromIconView(self);
    authenticateForApp(bid, name, ^{
        ((void(*)(id, SEL))orig_handleTap)(self, _cmd);
    });
}

// ═════════════════════════════════════════════════════════════════
// Constructor
// ═════════════════════════════════════════════════════════════════

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (![bid isEqualToString:@"com.apple.springboard"]) return;

        loadPrefs();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, onPrefsChanged,
            CFSTR(kBLNotification), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        // hook SBIconView._handleTap
        Class cls = objc_getClass("SBIconView");
        if (cls) {
            SEL sel = sel_registerName("_handleTap");
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                orig_handleTap = method_getImplementation(m);
                method_setImplementation(m, (IMP)hooked_handleTap);
                NSLog(@"[BioLock] ✅ hooked _handleTap");
            }
        }

        NSLog(@"[BioLock] ✅ loaded — %lu apps locked", (unsigned long)sLockedApps.count);
    }
}
