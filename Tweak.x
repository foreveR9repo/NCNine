#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
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
static CFAbsoluteTime gLastIntercept;   // dernier swipe que NOUS avons intercepté

static BOOL NCIsUnlocked(void) {
    Class c = NSClassFromString(@"SBLockScreenManager");
    if (!c || ![c respondsToSelector:@selector(sharedInstance)]) return NO;
    id m = [c sharedInstance];
    if (![m respondsToSelector:@selector(isUILocked)]) return NO;   // doute => on ne touche à rien
    return ![(SBLockScreenManager *)m isUILocked];
}

static void NCHideWhy(BOOL animated, NSString *why) {
    if (!gVisible) return;
    NCLOG(@"NC fermé par NOTRE code. animated=%d raison=%@", animated, why);
    gVisible = NO;
    UIWindow *w = gWindow; NCI9ViewController *vc = gVC;
    void (^done)(void) = ^{
        w.hidden = YES;
        if (gWindow == w) { gWindow = nil; gVC = nil; }
    };
    if (!animated || !vc) { done(); return; }
    [vc animateOutWithCompletion:done];
}

static UIWindowScene *NCMainScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)sc;
        if (ws.screen != UIScreen.mainScreen) continue;
        if ([NSStringFromClass(ws.class) hasPrefix:@"SBWindowScene"]) return ws;
        if (!fallback) fallback = ws;
    }
    return fallback;
}

static void NCShow(void) {
    if (gVisible) return;
    gVisible = YES;
    CGRect b = UIScreen.mainScreen.bounds;
    UIWindowScene *ws = NCMainScene();
    gWindow = ws ? [[UIWindow alloc] initWithWindowScene:ws] : [[UIWindow alloc] initWithFrame:b];
    gWindow.frame = b;
    gWindow.windowLevel = UIWindowLevelAlert + 1000;
    if ([gWindow respondsToSelector:@selector(_setSecure:)]) [gWindow _setSecure:YES];
    gWindow.backgroundColor = UIColor.clearColor;
    gVC = [NCI9ViewController new];
    gVC.requestDismiss = ^{ NCHideWhy(YES, @"poignée / glissement vers le haut / tap notification / Edit"); };
    gWindow.rootViewController = gVC;
    gWindow.hidden = NO;
    NCLOG(@"NC affiché: scene=%@ (%@) hidden=%d", gWindow.windowScene, ws ? NSStringFromClass(ws.class) : @"aucune scène trouvée", gWindow.hidden);
    [gVC animateIn];
}

// Vrai = un geste de PRÉSENTATION du CoverSheet doit être annulé : appareil déverrouillé,
// pas de verrouillage / réveil à l'instant, rideau natif pas déjà présenté.
// (Ne dépend PAS de gVisible : un même swipe active plusieurs reconnaisseurs et tous
//  doivent être annulés, pas seulement le premier.)
static BOOL NCShouldIntercept(void) {
    if (!NCIsUnlocked()) return NO;
    if (CFAbsoluteTimeGetCurrent() - gLastLockEvent < 1.0) return NO;
    Class pc = NSClassFromString(@"SBCoverSheetPresentationManager");
    if (pc && [pc respondsToSelector:@selector(sharedInstance)]) {
        id pm = [pc sharedInstance];
        if ([pm respondsToSelector:@selector(isPresented)] && [(SBCoverSheetPresentationManager *)pm isPresented]) return NO;
    }
    return YES;
}

static void NCCheckNativeCoverSheet(NSString *when) {
    Class pc = NSClassFromString(@"SBCoverSheetPresentationManager");
    if (!pc || ![pc respondsToSelector:@selector(sharedInstance)]) return;
    id pm = [pc sharedInstance];
    if (![pm respondsToSelector:@selector(isPresented)]) return;
    BOOL presented = [(SBCoverSheetPresentationManager *)pm isPresented];
    NCLOG(@"%@: CoverSheet natif présenté=%d, notre NC visible=%d, fenêtre cachée=%d",
          when, presented, gVisible, gWindow ? (int)gWindow.hidden : -1);
    // Si le rideau natif s'est présenté malgré tout, juste après NOTRE interception
    // et alors que l'appareil est déverrouillé, on le referme sans animation.
    if (presented && gVisible && NCIsUnlocked()) {
        SEL sel = NSSelectorFromString(@"setCoverSheetPresented:animated:withCompletion:");
        if ([pm respondsToSelector:sel]) {
            NCLOG(@"fermeture forcée du CoverSheet natif (déverrouillé, juste après notre interception)");
            ((void (*)(id, SEL, BOOL, BOOL, id))objc_msgSend)(pm, sel, NO, NO, nil);
        }
    }
}

static void NCReportAfterIntercept(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ NCCheckNativeCoverSheet(@"0.4 s"); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ NCCheckNativeCoverSheet(@"1.2 s"); });
}

static BOOL NCSwallowCoverSheetGesture(id g, UIGestureRecognizerState state) {
    if (state != UIGestureRecognizerStateBegan) return NO;
    if (!NCShouldIntercept()) return NO;
    gLastIntercept = CFAbsoluteTimeGetCurrent();
    if (gVisible) {
        NCLOG(@"geste %@ annulé (NC iOS 9 déjà affiché)", NSStringFromClass([g class]));
        return YES;
    }
    NCLOG(@"swipe-down déverrouillé: geste %@ annulé -> NC iOS 9", NSStringFromClass([g class]));
    dispatch_async(dispatch_get_main_queue(), ^{ NCShow(); });
    NCReportAfterIntercept();
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

// Présentation du CoverSheet : on ne bloque QUE dans la seconde et demie qui suit
// un swipe que nous avons nous-mêmes intercepté. Le verrouillage, le bouton latéral
// et le déverrouillage ne sont jamais concernés. Le reste est seulement journalisé.
%group GPresentation
%hook SBCoverSheetPresentationManager
- (void)setCoverSheetPresented:(BOOL)presented animated:(BOOL)animated withCompletion:(id)completion {
    BOOL recent = (CFAbsoluteTimeGetCurrent() - gLastIntercept) < 1.5;
    NCLOG(@"setCoverSheetPresented:%d animated:%d récent=%d", presented, animated, recent);
    if (presented && recent) { %orig(NO, animated, completion); return; }
    %orig;
}
%end
%end

// Delegate des gestes du CoverSheet : journalise quel geste demande à démarrer.
// Ne change rien, sauf juste après une interception de notre part.
%group GDelegate
%hook SBCoverSheetSystemGesturesDelegate
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    BOOL r = %orig;
    if (!r) return r;
    if (NCShouldIntercept()) {
        gLastIntercept = CFAbsoluteTimeGetCurrent();
        NCLOG(@"delegate: geste %@ refusé (déverrouillé, rideau natif non présenté)", NSStringFromClass([g class]));
        if (!gVisible) {
            dispatch_async(dispatch_get_main_queue(), ^{ NCShow(); });
            NCReportAfterIntercept();
        }
        return NO;
    }
    NCLOG(@"delegate shouldBegin: %@ orig=%d", NSStringFromClass([g class]), r);
    return r;
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
    NSString *name = (__bridge NSString *)n;
    dispatch_async(dispatch_get_main_queue(), ^{ NCHideWhy(NO, [NSString stringWithFormat:@"notification Darwin %@", name]); });
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

    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) NCLOG(@"scène: %@", sc);

    // Sondes passives (aucun effet, elles servent à régler les hooks suivants)
    NCProbe(@"SBLockScreenManager", @"isUILocked", NO);
    NCProbe(@"SBCoverSheetPresentationManager", @"isPresented", NO);
    NCProbe(@"SBHomeHardwareButtonActions", @"performSinglePressUpActions", NO);

    // setState: attendu : void, (id)self, (SEL)_cmd, (NSInteger)state
    if (NCCanHook(@"SBCoverSheetScreenEdgePanGestureRecognizer", @"setState:", "v24@0:8q16")) { %init(GEdgePan); }
    if (NCCanHook(@"SBCoverSheetPresentationGestureRecognizer", @"setState:", "v24@0:8q16")) { %init(GPresentationGesture); }
    if (NCCanHook(@"SBCoverSheetPresentationManager", @"setCoverSheetPresented:animated:withCompletion:", "v32@0:8B16B20@?24")) { %init(GPresentation); }
    if (NCCanHook(@"SBCoverSheetSystemGesturesDelegate", @"gestureRecognizerShouldBegin:", "B24@0:8@16")) { %init(GDelegate); }
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
