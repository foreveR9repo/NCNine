# NCNine (rootless, iOS 16-17, arm64/arm64e)

Build : `make package` (Theos, THEOS_PACKAGE_SCHEME=rootless déjà dans le Makefile) puis installer le .deb avec Dopamine.

## Ce qui est certain / à valider
Non testé sur appareil : je n'ai pas accès à ton iPhone. Les noms de classes privées ci-dessous
sont ceux que je connais pour iOS 15-17, à confirmer avec `class-dump`/FLEX sur ta version exacte.

| Hook | Rôle | Confiance |
|---|---|---|
| `SBLockScreenManager -isUILocked` | savoir si l'appareil est verrouillé | élevée |
| Darwin `com.apple.springboard.lockstate` / `hasBlankedScreen` | détecter verrouillage / réveil (remplace un hook de méthode) | élevée |
| `SBCoverSheetSystemGesturesDelegate -gestureRecognizerShouldBegin:` | **couche 1** : bloquer le swipe natif et afficher le NC | **à valider** (nom de classe) |
| `SBCoverSheetPresentationManager -setCoverSheetPresented:animated:withCompletion:` | **couche 2** : filet de sécurité | moyenne |
| `NCNotificationDispatcher -postNotificationWithRequest:` | récupérer les notifications en direct | moyenne |
| `SBHomeHardwareButtonActions -performSinglePressUpActions` | bouton Home ferme le NC | moyenne |

## Comment valider au premier test
Chaque hook de geste écrit une ligne `[NCNine] ...` dans les logs. Fais un swipe-down déverrouillé :
- ligne `gestureRecognizerShouldBegin` + NC iOS 9 : la couche 1 fonctionne ;
- seulement `setCoverSheetPresented` : la couche 1 n'est pas la bonne classe, la couche 2 prend le relais (un bout de rideau natif peut apparaître) ;
- aucune ligne : les deux noms de classes sont faux pour ta version.

## Debug sans respring loop
- Tout est gardé par `respondsToSelector:` / `@try`. En cas de doute, on laisse le CoverSheet natif.
- Logs : `NSLog` avec le préfixe `[NCNine]` (visible via la console / `oslog`).
- En cas de boucle : Dopamine > mode sans tweaks, ou supprimer `/var/jb/Library/MobileSubstrate/DynamicLibraries/NCNine.*`.
