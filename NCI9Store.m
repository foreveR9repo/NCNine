#import "NCI9Store.h"

NSString *const NCI9StoreDidChange = @"NCI9StoreDidChange";

@implementation NCI9Item @end

static id SafeKVC(id obj, NSString *key) {
    @try { return [obj valueForKey:key]; } @catch (__unused id e) { return nil; }
}

NSString *NCI9L(NSString *key) {
    static NSDictionary *fr, *en; static dispatch_once_t t;
    dispatch_once(&t, ^{
        en = @{@"today":@"Today", @"notifs":@"Notifications", @"edit":@"Edit",
               @"none":@"No Notifications", @"batteries":@"Batteries",
               @"iphone":@"iPhone", @"ago":@"%@ ago", @"now":@"now"};
        fr = @{@"today":@"Aujourd’hui", @"notifs":@"Notifications", @"edit":@"Modifier",
               @"none":@"Aucune notification", @"batteries":@"Batteries",
               @"iphone":@"iPhone", @"ago":@"il y a %@", @"now":@"maintenant"};
    });
    NSString *lang = [NSLocale preferredLanguages].firstObject ?: @"en";
    NSDictionary *d = [lang hasPrefix:@"fr"] ? fr : en;   // sinon anglais
    return d[key] ?: en[key] ?: key;
}

@implementation NCI9Store { NSMutableArray<NCI9Item *> *_items; }

+ (instancetype)shared {
    static NCI9Store *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [NCI9Store new]; });
    return s;
}
- (instancetype)init { if ((self = [super init])) _items = [NSMutableArray new]; return self; }
- (NSArray *)items { return [_items copy]; }

- (void)addRequest:(id)req {
    if (!req) return;
    id content = SafeKVC(req, @"content");
    NCI9Item *it = [NCI9Item new];
    it.identifier = SafeKVC(req, @"notificationIdentifier") ?: NSUUID.UUID.UUIDString;
    it.bundleID   = SafeKVC(req, @"sectionIdentifier") ?: @"";
    it.appName    = SafeKVC(content, @"header") ?: it.bundleID;
    it.title      = SafeKVC(content, @"title") ?: @"";
    it.message    = SafeKVC(content, @"message") ?: @"";
    it.date       = SafeKVC(content, @"date") ?: [NSDate date];
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NCI9Item *o in self->_items)
            if ([o.identifier isEqual:it.identifier]) { [self->_items removeObject:o]; break; }
        [self->_items insertObject:it atIndex:0];
        [[NSNotificationCenter defaultCenter] postNotificationName:NCI9StoreDidChange object:nil];
    });
}
- (void)removeItem:(NCI9Item *)item {
    [_items removeObject:item];
    [[NSNotificationCenter defaultCenter] postNotificationName:NCI9StoreDidChange object:nil];
}
- (void)removeAllForBundleID:(NSString *)b {
    NSPredicate *p = [NSPredicate predicateWithFormat:@"bundleID == %@", b];
    [_items removeObjectsInArray:[_items filteredArrayUsingPredicate:p]];
    [[NSNotificationCenter defaultCenter] postNotificationName:NCI9StoreDidChange object:nil];
}
@end
