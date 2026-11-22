# NCNine (rootless, iOS 16-17, arm64/arm64e)

Build : `make package` (Theos, THEOS_PACKAGE_SCHEME=rootless déjà dans le Makefile) puis installer le .deb avec Dopamine.

## Sécurité (v0.2)
- Aucun code ne s'exécute au chargement : tout démarre 6 s après, quand SpringBoard est prêt.
- Un hook n'est installé que si la méthode existe avec l'encodage de type attendu ; sinon il est ignoré
  et l'encodage réel est écrit dans le journal (`/var/mobile/Library/Logs/NCNine.log`).
- Aucun hook sur le verrouillage ni sur la présentation du CoverSheet. Seuls les gestes de swipe
  `SBCoverSheetScreenEdgePanGestureRecognizer` / `SBCoverSheetPresentationGestureRecognizer` sont ciblés.
- Garde anti-crash : si SpringBoard plante avant 30 s après le démarrage du tweak, il se désactive au
  démarrage suivant (10 min). Pour le réactiver : supprimer `/var/mobile/Library/NCNine.boot`.
- Pas encore gérés : bouton Home qui ferme le NC (signature à vérifier avec les sondes), rotation.

## Debug sans respring loop
- Tout est gardé par `respondsToSelector:` / `@try`. En cas de doute, on laisse le CoverSheet natif.
- Logs : `NSLog` avec le préfixe `[NCNine]` (visible via la console / `oslog`).
- En cas de boucle : Dopamine > mode sans tweaks, ou supprimer `/var/jb/Library/MobileSubstrate/DynamicLibraries/NCNine.*`.
