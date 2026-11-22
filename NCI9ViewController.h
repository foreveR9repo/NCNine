#import <UIKit/UIKit.h>

@interface NCI9ViewController : UIViewController
@property (nonatomic, copy) void (^requestDismiss)(void);
- (void)animateIn;
- (void)animateOutWithCompletion:(void (^)(void))c;
- (void)selectTabIndex:(NSInteger)i; // 0 = Today, 1 = Notifications
@end
