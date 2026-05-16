// BioLock — Lock apps with Face ID / passcode
// Runs only in SpringBoard.
// Features: icon tap lock, app switcher lock, switcher blur, notification lock, stealth mode

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <objc/runtime.h>

#define kBLPrefsPlist @"/var/jb/Library/Application Support/BioLock/prefs.plist"
#define kBLNotification "com.biolock.prefs/changed"
#define kBLStealthNotification "com.biolock.stealth/toggle"

// ═════════════════════════════════════════════════════════════════
// Forward declarations
// ═════════════════════════════════════════════════════════════════

@interface SBIcon : NSObject
- (NSString *)applicationBundleID;
- (NSString *)displayName;
@end

@interface SBIconView : UIView
- (SBIcon *)icon;
@end

@interface SBAppSwitcherModel : NSObject
@end

@interface SBMainSwitcherViewController : UIViewController
- (void)_switchToAppLayout:(id)layout;
@end

@interface SBReusableSnapshotItemContainer : UIView
@property (nonatomic, strong) NSString *displayItemIdentifier;
@end

@interface SBAppLayout : NSObject
@end

@interface SBDisplayItem : NSObject
@property (nonatomic, copy, readonly) NSString *bundleIdentifier;
@end

@interface SBFluidSwitcherItemContainer : UIView
- (SBDisplayItem *)displayItem;
@end

@interface SBNotificationBannerDestinationViewController : UIViewController
@end

@interface NCNotificationRequest : NSObject
- (NSString *)sectionIdentifier;
@end

@interface SBNCScreenController : NSObject
@end

@interface SBIconController : NSObject
+ (instancetype)sharedInstance;
- (void)_reloadIconModel;
@end

@interface SBIconModel : NSObject
- (NSArray *)visibleIconIdentifiers;
@end

@interface SBApplicationInfo : NSObject
- (NSString *)bundleIdentifier;
@end

// ═════════════════════════════════════════════════════════════════
// State
// ═════════════════════════════════════════════════════════════════

static BOOL sEnabled = NO;
static NSSet<NSString *> *sLockedApps = nil;
static BOOL sAuthInProgress = NO;

// stealth mode
static BOOL sStealthEnabled = NO;
static BOOL sStealthActive = NO;
static NSSet<NSString *> *sStealthHiddenApps = nil;
static NSInteger sStealthClickCount = 4; // default 4 clicks
static CFTimeInterval sStealthClickWindow = 1.2;

// power button tracking
static NSMutableArray *sPowerButtonTimestamps = nil;

static void loadPrefs(void) {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:kBLPrefsPlist];
    sEnabled = [p[@"enabled"] boolValue];
    NSArray *apps = p[@"lockedApps"];
    sLockedApps = apps ? [NSSet setWithArray:apps] : [NSSet set];

    // stealth mode prefs
    sStealthEnabled = [p[@"stealthEnabled"] boolValue];
    NSArray *hidden = p[@"stealthHiddenApps"];
    sStealthHiddenApps = hidden ? [NSSet setWithArray:hidden] : [NSSet set];
    NSInteger clicks = [p[@"stealthClickCount"] integerValue];
    if (clicks >= 3 && clicks <= 6) sStealthClickCount = clicks;
}

static void onPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n,
                            const void *obj, CFDictionaryRef i) {
    loadPrefs();
}

static BOOL isAppLocked(NSString *bid) {
    if (!sEnabled || !bid || !sLockedApps.count) return NO;
    return [sLockedApps containsObject:bid];
}

static BOOL isAppHiddenByStealth(NSString *bid) {
    if (!sStealthEnabled || !sStealthActive || !bid) return NO;
    return [sStealthHiddenApps containsObject:bid];
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

static void authenticateWithReason(NSString *reason, void (^onSuccess)(void)) {
    if (sAuthInProgress) return;
    sAuthInProgress = YES;

    LAContext *ctx = [[LAContext alloc] init];
    ctx.localizedFallbackTitle = @"Enter Passcode";

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

        if (error.code == LAErrorUserFallback ||
            error.code == LAErrorBiometryLockout ||
            error.code == LAErrorAuthenticationFailed) {
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
            dispatch_async(dispatch_get_main_queue(), ^{
                sAuthInProgress = NO;
            });
        }
    }];
}

// ═════════════════════════════════════════════════════════════════
// Hook 1: SBIconView._handleTap (icon tap on home screen)
// ═════════════════════════════════════════════════════════════════

static IMP orig_handleTap = NULL;

static void hooked_handleTap(id self, SEL _cmd) {
    NSString *bid = bidFromIconView(self);

    // stealth mode hides apps — if hidden, ignore tap entirely
    if (isAppHiddenByStealth(bid)) return;

    if (!bid || !isAppLocked(bid)) {
        ((void(*)(id, SEL))orig_handleTap)(self, _cmd);
        return;
    }

    NSString *name = nameFromIconView(self);
    NSString *reason = [NSString stringWithFormat:@"Unlock %@", name ?: @"this app"];
    authenticateWithReason(reason, ^{
        ((void(*)(id, SEL))orig_handleTap)(self, _cmd);
    });
}

// ═════════════════════════════════════════════════════════════════
// Hook 2: App Switcher — gate switching to locked apps
// ═════════════════════════════════════════════════════════════════

static IMP orig_switcherSelect = NULL;

static void hooked_switcherSelect(id self, SEL _cmd, id appLayout) {
    // try to extract bundle ID from the app layout
    NSString *bid = nil;
    @try {
        // SBAppLayout has displayItems → first item → bundleIdentifier
        NSArray *items = [appLayout performSelector:@selector(allItems)];
        if (items.count > 0) {
            id item = items[0];
            if ([item respondsToSelector:@selector(bundleIdentifier)])
                bid = [item bundleIdentifier];
        }
    } @catch (NSException *e) {}

    if (!bid || !isAppLocked(bid)) {
        ((void(*)(id, SEL, id))orig_switcherSelect)(self, _cmd, appLayout);
        return;
    }

    NSString *reason = [NSString stringWithFormat:@"Unlock %@", bid];
    authenticateWithReason(reason, ^{
        ((void(*)(id, SEL, id))orig_switcherSelect)(self, _cmd, appLayout);
    });
}

// ═════════════════════════════════════════════════════════════════
// Hook 3: App Switcher blur — overlay on locked app snapshots
// ═════════════════════════════════════════════════════════════════

static IMP orig_switcherItemDidAppear = NULL;
static const NSInteger kBLBlurTag = 0xB10C; // unique tag for our blur

static void hooked_switcherItemDidAppear(id self, SEL _cmd) {
    ((void(*)(id, SEL))orig_switcherItemDidAppear)(self, _cmd);

    NSString *bid = nil;
    @try {
        if ([self respondsToSelector:@selector(displayItem)]) {
            id item = [self performSelector:@selector(displayItem)];
            if ([item respondsToSelector:@selector(bundleIdentifier)])
                bid = [item bundleIdentifier];
        }
    } @catch (NSException *e) {}

    UIView *container = (UIView *)self;

    // remove existing blur if any
    UIView *existingBlur = [container viewWithTag:kBLBlurTag];

    if (bid && (isAppLocked(bid) || isAppHiddenByStealth(bid))) {
        if (!existingBlur) {
            UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial];
            UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:effect];
            blurView.frame = container.bounds;
            blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            blurView.tag = kBLBlurTag;

            // app icon in center of blur
            UIImageView *iconView = [[UIImageView alloc] init];
            UIImage *appIcon = [UIImage _applicationIconImageForBundleIdentifier:bid format:1
                                scale:[UIScreen mainScreen].scale];
            if (appIcon) {
                iconView.image = appIcon;
                iconView.frame = CGRectMake(0, 0, 60, 60);
                iconView.center = CGPointMake(blurView.bounds.size.width / 2,
                                             blurView.bounds.size.height / 2);
                iconView.autoresizingMask = UIViewAutoresizingFlexibleTopMargin |
                    UIViewAutoresizingFlexibleBottomMargin |
                    UIViewAutoresizingFlexibleLeftMargin |
                    UIViewAutoresizingFlexibleRightMargin;
                iconView.layer.cornerRadius = 13;
                iconView.layer.masksToBounds = YES;
                iconView.alpha = 0.6;
                [blurView.contentView addSubview:iconView];
            }

            // lock icon
            UIImageView *lockView = [[UIImageView alloc] initWithImage:
                [UIImage systemImageNamed:@"lock.fill"
                    withConfiguration:[UIImageSymbolConfiguration
                        configurationWithPointSize:20 weight:UIImageSymbolWeightMedium]]];
            lockView.tintColor = [UIColor whiteColor];
            lockView.frame = CGRectMake(0, 0, 24, 24);
            lockView.center = CGPointMake(blurView.bounds.size.width / 2,
                                         blurView.bounds.size.height / 2 + 46);
            lockView.autoresizingMask = UIViewAutoresizingFlexibleTopMargin |
                UIViewAutoresizingFlexibleBottomMargin |
                UIViewAutoresizingFlexibleLeftMargin |
                UIViewAutoresizingFlexibleRightMargin;
            [blurView.contentView addSubview:lockView];

            [container addSubview:blurView];
        }
    } else {
        [existingBlur removeFromSuperview];
    }
}

// ═════════════════════════════════════════════════════════════════
// Hook 4: Notification tap — gate opening locked apps from banners
// ═════════════════════════════════════════════════════════════════

static IMP orig_notifAction = NULL;

static void hooked_notifAction(id self, SEL _cmd, id request, id completion) {
    NSString *bid = nil;
    @try {
        if ([request respondsToSelector:@selector(sectionIdentifier)])
            bid = [request performSelector:@selector(sectionIdentifier)];
    } @catch (NSException *e) {}

    if (!bid || !isAppLocked(bid)) {
        ((void(*)(id, SEL, id, id))orig_notifAction)(self, _cmd, request, completion);
        return;
    }

    NSString *reason = [NSString stringWithFormat:@"Unlock %@", bid];
    authenticateWithReason(reason, ^{
        ((void(*)(id, SEL, id, id))orig_notifAction)(self, _cmd, request, completion);
    });
}

// ═════════════════════════════════════════════════════════════════
// Hook 5: Stealth Mode — power button rapid press detection
// ═════════════════════════════════════════════════════════════════

static void refreshIconVisibility(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // force SpringBoard to reload its icon model
        Class SBIconControllerClass = objc_getClass("SBIconController");
        if (SBIconControllerClass) {
            id shared = [SBIconControllerClass performSelector:@selector(sharedInstance)];
            if ([shared respondsToSelector:@selector(_reloadIconModel)])
                [shared performSelector:@selector(_reloadIconModel)];
        }
    });
}

static void toggleStealthMode(void) {
    sStealthActive = !sStealthActive;

    NSLog(@"[BioLock] 🕶️ Stealth mode %@", sStealthActive ? @"ACTIVATED" : @"DEACTIVATED");

    // post notification so UI can respond
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(kBLStealthNotification), NULL, NULL, YES);

    refreshIconVisibility();

    // subtle haptic feedback
    dispatch_async(dispatch_get_main_queue(), ^{
        UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc]
            initWithStyle:sStealthActive ? UIImpactFeedbackStyleHeavy : UIImpactFeedbackStyleMedium];
        [gen prepare];
        [gen impactOccurred];
        if (sStealthActive) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                [gen impactOccurred]; // double tap feedback for activation
            });
        }
    });
}

static void handlePowerButtonPress(void) {
    if (!sStealthEnabled) return;

    CFTimeInterval now = CACurrentMediaTime();
    if (!sPowerButtonTimestamps)
        sPowerButtonTimestamps = [NSMutableArray new];

    [sPowerButtonTimestamps addObject:@(now)];

    // remove old timestamps outside window
    while (sPowerButtonTimestamps.count > 0) {
        CFTimeInterval oldest = [sPowerButtonTimestamps[0] doubleValue];
        if (now - oldest > sStealthClickWindow) {
            [sPowerButtonTimestamps removeObjectAtIndex:0];
        } else {
            break;
        }
    }

    if ((NSInteger)sPowerButtonTimestamps.count >= sStealthClickCount) {
        [sPowerButtonTimestamps removeAllObjects];
        toggleStealthMode();
    }
}

// Hook the lock button press handler
static IMP orig_lockButtonDown = NULL;

static void hooked_lockButtonDown(id self, SEL _cmd, id event) {
    ((void(*)(id, SEL, id))orig_lockButtonDown)(self, _cmd, event);
    handlePowerButtonPress();
}

// ═════════════════════════════════════════════════════════════════
// Hook 6: Stealth Mode — hide icons from SpringBoard
// ═════════════════════════════════════════════════════════════════

static IMP orig_iconAllowed = NULL;

// SBIconModel or SBLeafIcon visibility check
static BOOL hooked_iconAllowed(id self, SEL _cmd) {
    NSString *bid = nil;
    @try {
        if ([self respondsToSelector:@selector(applicationBundleID)])
            bid = [self performSelector:@selector(applicationBundleID)];
    } @catch (NSException *e) {}

    if (isAppHiddenByStealth(bid)) return NO;

    return ((BOOL(*)(id, SEL))orig_iconAllowed)(self, _cmd);
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

        // ─── Hook 1: Icon tap ───
        Class iconViewCls = objc_getClass("SBIconView");
        if (iconViewCls) {
            SEL sel = sel_registerName("_handleTap");
            Method m = class_getInstanceMethod(iconViewCls, sel);
            if (m) {
                orig_handleTap = method_getImplementation(m);
                method_setImplementation(m, (IMP)hooked_handleTap);
                NSLog(@"[BioLock] ✅ hooked _handleTap");
            }
        }

        // ─── Hook 2: App Switcher selection ───
        Class switcherCls = objc_getClass("SBMainSwitcherViewController");
        if (switcherCls) {
            // iOS 15: _activateAppLayout: or _selectAppLayout:
            SEL selectors[] = {
                sel_registerName("_activateAppLayout:"),
                sel_registerName("_selectAppLayout:"),
                sel_registerName("activateAppLayout:"),
                sel_registerName("selectItem:"),
            };
            for (int i = 0; i < 4; i++) {
                Method m = class_getInstanceMethod(switcherCls, selectors[i]);
                if (m) {
                    orig_switcherSelect = method_getImplementation(m);
                    method_setImplementation(m, (IMP)hooked_switcherSelect);
                    NSLog(@"[BioLock] ✅ hooked switcher: %s", sel_getName(selectors[i]));
                    break;
                }
            }
        }

        // ─── Hook 3: Switcher snapshot blur ───
        Class switcherItemCls = objc_getClass("SBFluidSwitcherItemContainer");
        if (switcherItemCls) {
            SEL sel = sel_registerName("didMoveToWindow");
            Method m = class_getInstanceMethod(switcherItemCls, sel);
            if (m) {
                orig_switcherItemDidAppear = method_getImplementation(m);
                method_setImplementation(m, (IMP)hooked_switcherItemDidAppear);
                NSLog(@"[BioLock] ✅ hooked switcher item blur");
            }
        }

        // ─── Hook 4: Notification action ───
        // NCNotificationDispatcher or UserNotificationsServer handles taps
        Class notifCls = objc_getClass("NCNotificationDispatcher");
        if (!notifCls) notifCls = objc_getClass("SBNCNotificationDispatcher");
        if (notifCls) {
            SEL selectors[] = {
                sel_registerName("destination:executeAction:forNotificationRequest:requestAuthentication:withParameters:completion:"),
                sel_registerName("destination:executeAction:forNotificationRequest:withParameters:completion:"),
                sel_registerName("_executeAction:forNotificationRequest:completion:"),
                sel_registerName("_handleTapActionForNotificationRequest:completion:"),
            };
            for (int i = 0; i < 4; i++) {
                Method m = class_getInstanceMethod(notifCls, selectors[i]);
                if (m) {
                    orig_notifAction = method_getImplementation(m);
                    method_setImplementation(m, (IMP)hooked_notifAction);
                    NSLog(@"[BioLock] ✅ hooked notification dispatch: %s", sel_getName(selectors[i]));
                    break;
                }
            }
        }
        // fallback: hook SBNotificationBannerDestination
        if (!orig_notifAction) {
            Class bannerCls = objc_getClass("SBNotificationBannerDestination");
            if (bannerCls) {
                SEL sel = sel_registerName("_handleTapActionForNotificationRequest:completion:");
                Method m = class_getInstanceMethod(bannerCls, sel);
                if (m) {
                    orig_notifAction = method_getImplementation(m);
                    method_setImplementation(m, (IMP)hooked_notifAction);
                    NSLog(@"[BioLock] ✅ hooked banner notification tap");
                }
            }
        }

        // ─── Hook 5: Power/lock button for stealth mode ───
        Class sbCls = objc_getClass("SpringBoard");
        if (sbCls) {
            SEL selectors[] = {
                sel_registerName("_lockButtonDown:"),
                sel_registerName("lockButtonDown:"),
                sel_registerName("_handlePhysicalButtonEvent:"),
            };
            for (int i = 0; i < 3; i++) {
                Method m = class_getInstanceMethod(sbCls, selectors[i]);
                if (m) {
                    orig_lockButtonDown = method_getImplementation(m);
                    method_setImplementation(m, (IMP)hooked_lockButtonDown);
                    NSLog(@"[BioLock] ✅ hooked power button: %s", sel_getName(selectors[i]));
                    break;
                }
            }
        }

        // ─── Hook 6: Icon visibility for stealth mode ───
        Class leafIconCls = objc_getClass("SBLeafIcon");
        if (!leafIconCls) leafIconCls = objc_getClass("SBApplicationIcon");
        if (leafIconCls) {
            SEL selectors[] = {
                sel_registerName("isVisibleForIconModel:"),
                sel_registerName("_isVisible"),
                sel_registerName("isVisible"),
            };
            for (int i = 0; i < 3; i++) {
                Method m = class_getInstanceMethod(leafIconCls, selectors[i]);
                if (m) {
                    orig_iconAllowed = method_getImplementation(m);
                    method_setImplementation(m, (IMP)hooked_iconAllowed);
                    NSLog(@"[BioLock] ✅ hooked icon visibility: %s", sel_getName(selectors[i]));
                    break;
                }
            }
        }

        NSLog(@"[BioLock] ✅ loaded — %lu locked, %lu stealth-hidden, stealth %@",
              (unsigned long)sLockedApps.count,
              (unsigned long)sStealthHiddenApps.count,
              sStealthEnabled ? @"enabled" : @"disabled");
    }
}
