# NCNine (rootless, iOS 16-17, arm64/arm64e)

Build : `make package` (Theos, THEOS_PACKAGE_SCHEME=rootless déjà dans le Makefile) puis installer le .deb avec Dopamine.

## Ce qui est certain / à valider
Non testé sur appareil : je n'ai pas accès à ton iPhone. Les noms de classes privées ci-dessous
sont ceux que je connais pour iOS 15-17, à confirmer avec `class-dump`/FLEX sur ta version exacte.

| Hook | Rôle | Confiance |
|---|---|---|
| `SBLockScreenManager -isUILocked` | savoir si l'appareil est verrouillé | élevée |
| `SBLockScreenManager -lockUIFromSource:withOptions:` | marquer le verrouillage manuel | moyenne (signature) |
| `SBCoverSheetPresentationManager -setCoverSheetPresented:animated:withCompletion:` | point d'entrée de la présentation du CoverSheet | **à valider** |
| `NCNotificationDispatcher -postNotificationWithRequest:` | récupérer les notifications en direct | moyenne |
| `SBHomeHardwareButtonActions -performSinglePressUpActions` | bouton Home ferme le NC | moyenne |

## Limite connue du hook CoverSheet
Le swipe-down est un geste **interactif** : le rideau natif peut déjà suivre le doigt avant que
`setCoverSheetPresented:` soit appelé. Si c'est le cas sur ta version, la solution propre est
d'intercepter le geste lui-même (reconnaisseur de bord haut du CoverSheet, désactivé quand
`!isUILocked`, remplacé par un `UIScreenEdgePanGestureRecognizer` maison). Envoie-moi ta version
d'iOS et le comportement observé, je cible alors le bon point d'entrée.

## Debug sans respring loop
- Tout est gardé par `respondsToSelector:` / `@try`. En cas de doute, on laisse le CoverSheet natif.
- Logs : `NSLog` avec le préfixe `[NCNine]` (visible via la console / `oslog`).
- En cas de boucle : Dopamine > mode sans tweaks, ou supprimer `/var/jb/Library/MobileSubstrate/DynamicLibraries/NCNine.*`.
