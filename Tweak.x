#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <string.h>
#import "NCI9Store.h"
#import "NCI9ViewController.h"

// ===========================================================================
// NCNine : règles de sécurité de ce fichier
//  1. Rien n'est touché pendant le chargement (%ctor). Tout démarre 6 s après,
//     quand SpringBoard a fini de s'initialiser.
//  2. Un hook n'est installé que si la méthode existe ET que son encodage de
//     type est exactement celui attendu (sinon il est ignoré et journalisé).
//  3. Garde anti-crash : si SpringBoard a planté après notre dernier démarrage,
//     le tweak se désactive tout seul (fichier /var/mobile/Library/NCNine.boot).
//  4. On ne hooke AUCUNE méthode de verrouillage ni de présentation du
//     CoverSheet : seuls les gestes de swipe depuis le haut sont ciblés.
// ===========================================================================

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUILocked;
@end

@interface SBCoverSheetPresentationManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isPresented;
@end

@interface SBCoverSheetScreenEdgePanGestureRecognizer : UIGestureRecognizer
@end
@interface SBCoverSheetPresentationGestureRecognizer : UIGestureRecognizer
@end

@interface UIWindow (NCNinePrivate)
- (void)_setSecure:(BOOL)secure;
@end

// ---------------------------------------------------------------------------
// Journal : /var/mobile/Library/Logs/NCNine.log
// ---------------------------------------------------------------------------
static void NCLogString(NSString *msg) {
    NSLog(@"[NCNine] %@", msg);
    static dispatch_queue_t q; static dispatch_once_t t;
    dispatch_once(&t, ^{ q = dispatch_queue_create("ncnine.log", DISPATCH_QUEUE_SERIAL); });
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    dispatch_async(q, ^{
        NSString *path = @"/var/mobile/Library/Logs/NCNine.log";
        NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        if ([a fileSize] > 200 * 1024) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!h) { [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil]; return; }
        [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
    });
}
#define NCLOG(fmt, ...) NCLogString([NSString stringWithFormat:fmt, ##__VA_ARGS__])

// ---------------------------------------------------------------------------
// Fenêtre + contrôleur
// ---------------------------------------------------------------------------
static UIWindow *gWindow;
static NCI9ViewController *gVC;
static BOOL gVisible;
static CFAbsoluteTime gLastLockEvent;

static BOOL NCIsUnlocked(void) {
    Class c = NSClassFromString(@"SBLockScreenManager");
    if (!c || ![c respondsToSelector:@selector(sharedInstance)]) return NO;
    id m = [c sharedInstance];
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
    gWindow.windowLevel = UIWindowLevelAlert + 1000;
    if ([gWindow respondsToSelector:@selector(_setSecure:)]) [gWindow _setSecure:YES];
    gWindow.backgroundColor = UIColor.clearColor;
    gVC = [NCI9ViewController new];
    gVC.requestDismiss = ^{ NCHide(YES); };
    gWindow.rootViewController = gVC;
    gWindow.transform = CGAffineTransformMakeTranslation(0, -b.size.height);
    gWindow.hidden = NO;
    NCLOG(@"NC affiché: scene=%@ hidden=%d", gWindow.windowScene, gWindow.hidden);
    [UIView animateWithDuration:.32 delay:0 usingSpringWithDamping:.95 initialSpringVelocity:0 options:0 animations:^{
        gWindow.transform = CGAffineTransformIdentity;
    } completion:nil];
}

static BOOL NCShouldIntercept(void) {
    if (gVisible) return NO;
    if (!NCIsUnlocked()) return NO;
    if (CFAbsoluteTimeGetCurrent() - gLastLockEvent < 1.0) return NO;
    Class pc = NSClassFromString(@"SBCoverSheetPresentationManager");
    if (pc && [pc respondsToSelector:@selector(sharedInstance)]) {
        id pm = [pc sharedInstance];
        if ([pm respondsToSelector:@selector(isPresented)] && [(SBCoverSheetPresentationManager *)pm isPresented]) return NO;
    }
    return YES;
}

static BOOL NCSwallowCoverSheetGesture(id g, UIGestureRecognizerState state) {
    if (state != UIGestureRecognizerStateBegan) return NO;
    if (!NCShouldIntercept()) return NO;
    NCLOG(@"swipe-down déverrouillé: geste %@ annulé -> NC iOS 9", NSStringFromClass([g class]));
    dispatch_async(dispatch_get_main_queue(), ^{ NCShow(); });
    return YES;
}

// ---------------------------------------------------------------------------
// Hooks (chacun dans un groupe, installé seulement s'il est sûr)
// ---------------------------------------------------------------------------
%group GEdgePan
%hook SBCoverSheetScreenEdgePanGestureRecognizer
- (void)setState:(UIGestureRecognizerState)state {
    if (NCSwallowCoverSheetGesture(self, state)) { %orig(UIGestureRecognizerStateFailed); return; }
    %orig;
}
%end
%end

%group GPresentationGesture
%hook SBCoverSheetPresentationGestureRecognizer
- (void)setState:(UIGestureRecognizerState)state {
    if (NCSwallowCoverSheetGesture(self, state)) { %orig(UIGestureRecognizerStateFailed); return; }
    %orig;
}
%end
%end

%group GNotifications
%hook NCNotificationDispatcher
- (void)postNotificationWithRequest:(id)request {
    %orig;
    [[NCI9Store shared] addRequest:request];
}
%end
%end

// ---------------------------------------------------------------------------
// Vérifications passives
// ---------------------------------------------------------------------------
static const char *NCEncoding(NSString *cls, NSString *sel, BOOL classMethod) {
    Class c = NSClassFromString(cls);
    if (!c) return NULL;
    SEL s = NSSelectorFromString(sel);
    Method m = classMethod ? class_getClassMethod(c, s) : class_getInstanceMethod(c, s);
    return m ? method_getTypeEncoding(m) : NULL;
}

static BOOL NCCanHook(NSString *cls, NSString *sel, const char *expected) {
    const char *e = NCEncoding(cls, sel, NO);
    BOOL ok = (e != NULL) && strcmp(e, expected) == 0;
    NCLOG(@"%@ %@ : %s -> %@", cls, sel, e ? e : "ABSENT", ok ? @"hook installé" : @"hook NON installé");
    return ok;
}

static void NCProbe(NSString *cls, NSString *sel, BOOL classMethod) {
    const char *e = NCEncoding(cls, sel, classMethod);
    NCLOG(@"[sonde] %@ %@ : %s", cls, sel, e ? e : "ABSENT");
}

// ---------------------------------------------------------------------------
// Garde anti-crash
// ---------------------------------------------------------------------------
static NSString *const kBootPath = @"/var/mobile/Library/NCNine.boot";

static BOOL NCCrashGuardAllowsStart(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kBootPath];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (d && ![d[@"stable"] boolValue] && now - [d[@"t"] doubleValue] < 600) return NO;
    [@{@"t": @(now), @"stable": @NO} writeToFile:kBootPath atomically:YES];
    return YES;
}

static void NCMarkStable(void) {
    [@{@"t": @([[NSDate date] timeIntervalSince1970]), @"stable": @YES} writeToFile:kBootPath atomically:YES];
}

static void NCLockEvent(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    gLastLockEvent = CFAbsoluteTimeGetCurrent();
    dispatch_async(dispatch_get_main_queue(), ^{ NCHide(NO); });
}

// ---------------------------------------------------------------------------
// Démarrage différé
// ---------------------------------------------------------------------------
static void NCStart(void) {
    NCLOG(@"démarrage différé. iOS %@", UIDevice.currentDevice.systemVersion);
    if (!NCCrashGuardAllowsStart()) {
        NCLOG(@"GARDE ANTI-CRASH: SpringBoard a planté après le dernier démarrage, tweak désactivé. Supprime %@ pour le réactiver.", kBootPath);
        return;
    }

    // Sondes passives (aucun effet, elles servent à régler les hooks suivants)
    NCProbe(@"SBLockScreenManager", @"isUILocked", NO);
    NCProbe(@"SBCoverSheetPresentationManager", @"isPresented", NO);
    NCProbe(@"SBCoverSheetPresentationManager", @"setCoverSheetPresented:animated:withCompletion:", NO);
    NCProbe(@"SBHomeHardwareButtonActions", @"performSinglePressUpActions", NO);
    NCProbe(@"SBCoverSheetSystemGesturesDelegate", @"gestureRecognizerShouldBegin:", NO);

    // setState: attendu : void, (id)self, (SEL)_cmd, (NSInteger)state
    if (NCCanHook(@"SBCoverSheetScreenEdgePanGestureRecognizer", @"setState:", "v24@0:8q16")) { %init(GEdgePan); }
    if (NCCanHook(@"SBCoverSheetPresentationGestureRecognizer", @"setState:", "v24@0:8q16")) { %init(GPresentationGesture); }
    if (NCCanHook(@"NCNotificationDispatcher", @"postNotificationWithRequest:", "v24@0:8@16")) { %init(GNotifications); }

    CFNotificationCenterRef d = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(d, NULL, NCLockEvent, CFSTR("com.apple.springboard.lockstate"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(d, NULL, NCLockEvent, CFSTR("com.apple.springboard.hasBlankedScreen"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NCMarkStable();
        NCLOG(@"stable depuis 30 s");
    });
}

%ctor {
    // Rien d'autre ici : on ne touche à aucune classe SpringBoard pendant le chargement.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NCStart();
    });
}
