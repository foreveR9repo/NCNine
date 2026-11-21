#import <UIKit/UIKit.h>

@interface NCI9Item : NSObject
@property (nonatomic, copy) NSString *identifier, *bundleID, *appName, *title, *message;
@property (nonatomic, strong) NSDate *date;
@end

extern NSString *const NCI9StoreDidChange;

@interface NCI9Store : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) NSArray<NCI9Item *> *items;
- (void)addRequest:(id)notificationRequest;   // NCNotificationRequest
- (void)removeItem:(NCI9Item *)item;
- (void)removeAllForBundleID:(NSString *)bundleID;
@end

// Localisation minimale (fr / en)
NSString *NCI9L(NSString *key);
