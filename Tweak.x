#import <UIKit/UIKit.h>
#import <notify.h>
#import "NCI9Store.h"
#import "NCI9ViewController.h"

// ---------------------------------------------------------------------------
// Déclarations minimales (classes privées SpringBoard)
// ---------------------------------------------------------------------------
@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUILocked;
@end

@interface SBCoverSheetPresentationManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isPresented;
@end

@interface UIWindow (NCNinePrivate)
- (void)_setSecure:(BOOL)secure;
@end

#define NCLOG(fmt, ...) NSLog(@"[NCNine] " fmt, ##__VA_ARGS__)

// ---------------------------------------------------------------------------
// Fenêtre + contrôleur
// ---------------------------------------------------------------------------
static UIWindow *gWindow;
static NCI9ViewController *gVC;
static BOOL gVisible;
static CFAbsoluteTime gLastLockEvent;   // dernier changement d'état verrouillage / écran

static BOOL NCIsUnlocked(void) {
    id m = [NSClassFromString(@"SBLockScreenManager") sharedInstance];
    if (![m respondsToSelector:@selector(isUILocked)]) return NO;   // doute => on ne touche à rien
    return ![(SBLockScreenManager *)m isUILocked];
}

static void NCHide(BOOL animated) {
    if (!gVisible) return;
    gVisible = NO;
    UIWindow *w = gWindow;
    void (^done)(BOOL) = ^(BOOL f) {
        w.hidden = YES;
        if (gWindow == w) { gWindow = nil; gVC = nil; }
    };
    if (!animated) { done(YES); return; }
    [UIView animateWithDuration:.28 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        w.transform = CGAffineTransformMakeTranslation(0, -w.bounds.size.height);
    } completion:done];
}

static void NCShow(void) {
    if (gVisible) return;
    gVisible = YES;
    CGRect b = UIScreen.mainScreen.bounds;
    gWindow = [[UIWindow alloc] initWithFrame:b];
    gWindow.windowLevel = UIWindowLevelAlert + 1000;   // au-dessus de l'app et des bannières
    if ([gWindow respondsToSelector:@selector(_setSecure:)]) [gWindow _setSecure:YES];
    gWindow.backgroundColor = UIColor.clearColor;
    gVC = [NCI9ViewController new];
    gVC.requestDismiss = ^{ NCHide(YES); };
    gWindow.rootViewController = gVC;
    gWindow.transform = CGAffineTransformMakeTranslation(0, -b.size.height);
    gWindow.hidden = NO;
    [UIView animateWithDuration:.32 delay:0 usingSpringWithDamping:.95 initialSpringVelocity:0 options:0 animations:^{
        gWindow.transform = CGAffineTransformIdentity;
    } completion:nil];
}

// ---------------------------------------------------------------------------
// Décision : intercepter ou laisser le CoverSheet natif ?
// On n'intercepte QUE si :
//  - l'appareil est déverrouillé,
//  - aucun changement d'état verrouillage / écran dans la dernière seconde
//    (bouton latéral, réveil, déverrouillage),
//  - le CoverSheet n'est pas déjà présenté,
//  - notre NC n'est pas déjà visible.
// ---------------------------------------------------------------------------
static BOOL NCShouldIntercept(void) {
    if (gVisible) return NO;
    if (!NCIsUnlocked()) return NO;
    if (CFAbsoluteTimeGetCurrent() - gLastLockEvent < 1.0) return NO;
    id pm = [NSClassFromString(@"SBCoverSheetPresentationManager") sharedInstance];
    if ([pm respondsToSelector:@selector(isPresented)] && [(SBCoverSheetPresentationManager *)pm isPresented]) return NO;
    return YES;
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

// Couche 1 (préférée) : le geste de swipe-down lui-même.
// Le delegate des gestes système du CoverSheet décide si le geste démarre.
// Si on est déverrouillé : on affiche notre NC et on refuse le geste natif,
// donc le rideau natif n'apparaît jamais, même pas à moitié.
%hook SBCoverSheetSystemGesturesDelegate
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    BOOL r = %orig;
    if (!r) return r;
    NCLOG(@"gestureRecognizerShouldBegin: %@ state-unlocked=%d", NSStringFromClass(g.class), NCIsUnlocked());
    if (![g isKindOfClass:UIPanGestureRecognizer.class]) return r;
    if (!NCShouldIntercept()) return r;
    CGPoint p = [g locationInView:g.view];
    if (p.y > 150) return r;               // geste parti du haut de l'écran uniquement
    NCLOG(@"swipe-down déverrouillé -> NC iOS 9 (geste bloqué)");
    dispatch_async(dispatch_get_main_queue(), ^{ NCShow(); });
    return NO;
}
%end

// Couche 2 (filet de sécurité) : si le CoverSheet est tout de même présenté
// alors qu'on est déverrouillé, on demande l'état « non présenté » au lieu de
// bloquer l'appel : l'original gère lui-même sa complétion.
%hook SBCoverSheetPresentationManager
- (void)setCoverSheetPresented:(BOOL)presented animated:(BOOL)animated withCompletion:(id)completion {
    NCLOG(@"setCoverSheetPresented:%d unlocked=%d", presented, NCIsUnlocked());
    if (presented && NCShouldIntercept()) {
        dispatch_async(dispatch_get_main_queue(), ^{ NCShow(); });
        %orig(NO, animated, completion);
        return;
    }
    %orig;
}
%end

// Source de notifications : toute notification postée passe par le dispatcher.
%hook NCNotificationDispatcher
- (void)postNotificationWithRequest:(id)request {
    %orig;
    [[NCI9Store shared] addRequest:request];
}
%end

// Bouton Home physique (SE 2020) : ferme le NC custom.
%hook SBHomeHardwareButtonActions
- (void)performSinglePressUpActions {
    if (gVisible) { NCHide(YES); return; }
    %orig;
}
%end

// ---------------------------------------------------------------------------
// Notifications Darwin : verrouillage / extinction / réveil de l'écran.
// Remplace le hook de lockUIFromSource: (signature incertaine selon la version).
// ---------------------------------------------------------------------------
static void NCLockEvent(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    gLastLockEvent = CFAbsoluteTimeGetCurrent();
    dispatch_async(dispatch_get_main_queue(), ^{ NCHide(NO); });
}

%ctor {
    CFNotificationCenterRef d = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(d, NULL, NCLockEvent, CFSTR("com.apple.springboard.lockstate"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(d, NULL, NCLockEvent, CFSTR("com.apple.springboard.hasBlankedScreen"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    // Rotation : on referme (layout paysage non reproduit). On ignore à plat / inconnu.
    [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification
                                                      object:nil queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *n) {
        UIDeviceOrientation o = UIDevice.currentDevice.orientation;
        if (UIDeviceOrientationIsPortrait(o) || UIDeviceOrientationIsLandscape(o)) NCHide(NO);
    }];
    [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
    NCLOG(@"chargé");
}
