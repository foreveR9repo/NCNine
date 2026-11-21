#import <UIKit/UIKit.h>
#import "NCI9Store.h"
#import "NCI9ViewController.h"

// ---------------------------------------------------------------------------
// Déclarations minimales (classes privées SpringBoard iOS 15-17)
// ---------------------------------------------------------------------------
@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUILocked;
@end

@interface SBCoverSheetPresentationManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isPresented;
@end

@interface UIWindow (NCI9Private)
- (void)_setSecure:(BOOL)secure;
@end

#define NCI9LOG(fmt, ...) NSLog(@"[NCNine] " fmt, ##__VA_ARGS__)

// ---------------------------------------------------------------------------
// Fenêtre + contrôleur
// ---------------------------------------------------------------------------
static UIWindow *gWindow;
static NCI9ViewController *gVC;
static BOOL gVisible;
static CFAbsoluteTime gLastLockRequest;   // anti-confusion avec le bouton latéral / verrouillage

static BOOL NCI9IsUnlocked(void) {
    SBLockScreenManager *m = [NSClassFromString(@"SBLockScreenManager") sharedInstance];
    if (![m respondsToSelector:@selector(isUILocked)]) return NO;   // doute => on ne touche à rien
    return ![m isUILocked];
}

static void NCI9Hide(BOOL animated) {
    if (!gVisible) return;
    gVisible = NO;
    UIWindow *w = gWindow;
    void (^done)(BOOL) = ^(BOOL f) { w.hidden = YES; if (gWindow == w) { gWindow = nil; gVC = nil; } };
    if (!animated) { done(YES); return; }
    [UIView animateWithDuration:.28 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        w.transform = CGAffineTransformMakeTranslation(0, -w.bounds.size.height);
    } completion:done];
}

static void NCI9Show(void) {
    if (gVisible) return;
    gVisible = YES;
    CGRect b = UIScreen.mainScreen.bounds;
    gWindow = [[UIWindow alloc] initWithFrame:b];
    gWindow.windowLevel = UIWindowLevelAlert + 1000;   // au-dessus de l'app et des bannières
    if ([gWindow respondsToSelector:@selector(_setSecure:)]) [gWindow _setSecure:YES];
    gWindow.backgroundColor = UIColor.clearColor;
    gVC = [NCI9ViewController new];
    gVC.requestDismiss = ^{ NCI9Hide(YES); };
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
//  - aucun verrouillage n'a été demandé dans la dernière seconde (bouton latéral),
//  - le CoverSheet n'est pas déjà présenté.
// ---------------------------------------------------------------------------
static BOOL NCI9ShouldIntercept(void) {
    if (!NCI9IsUnlocked()) return NO;
    if (CFAbsoluteTimeGetCurrent() - gLastLockRequest < 1.0) return NO;
    SBCoverSheetPresentationManager *pm = [NSClassFromString(@"SBCoverSheetPresentationManager") sharedInstance];
    if ([pm respondsToSelector:@selector(isPresented)] && [pm isPresented]) return NO;
    return YES;
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------
%hook SBLockScreenManager
// Marque toute demande de verrouillage (bouton latéral, auto-lock) pour ne jamais l'intercepter.
- (void)lockUIFromSource:(int)source withOptions:(id)options {
    gLastLockRequest = CFAbsoluteTimeGetCurrent();
    NCI9Hide(NO);
    %orig;
}
%end

%hook SBCoverSheetPresentationManager
// ⚠ POINT À VALIDER sur ta version d'iOS (voir README) : c'est le point d'entrée
// de la présentation du CoverSheet. Si la signature diffère, adapter ici.
- (void)setCoverSheetPresented:(BOOL)presented animated:(BOOL)animated withCompletion:(id)completion {
    if (presented && NCI9ShouldIntercept()) {
        NCI9LOG(@"swipe-down déverrouillé intercepté -> NC iOS 9");
        dispatch_async(dispatch_get_main_queue(), ^{ NCI9Show(); });
        void (^c)(void) = completion;
        if (c) c();           // on ne bloque pas l'appelant
        return;               // pas de %orig => pas de CoverSheet
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
    if (gVisible) { NCI9Hide(YES); return; }
    %orig;
}
%end

%ctor {
    // Rotation : on referme plutôt que de gérer un layout paysage non reproduit.
    [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification
                                                      object:nil queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *n) { NCI9Hide(NO); }];
    [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
    NCI9LOG(@"chargé");
}
