#import "NCI9ViewController.h"
#import "NCI9Store.h"

@interface UIImage (NCI9Private)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)b format:(int)f scale:(CGFloat)s;
@end
@interface SpringBoard : UIApplication
- (BOOL)launchApplicationWithIdentifier:(NSString *)i suspended:(BOOL)s;
@end

// ---- Constantes mesurées sur les captures (iPhone 6 / SE 2020 : 375x667 pt) ----
static const CGFloat kSegX = 31.5, kSegY = 24, kSegH = 28;   // segment Today | Notifications
static const CGFloat kRuleY = 63;                            // filet sous le segment
static const CGFloat kSectionH = 32;                         // bande de section
static const CGFloat kTextX = 48;                            // retrait du texte
static const CGFloat kHandleH = 31;                          // poignée du bas

static UIColor *Tint(void)      { return [UIColor colorWithWhite:1 alpha:0.35]; }
static UIColor *BandColor(void) { return [UIColor colorWithWhite:0 alpha:0.30]; }
static UIColor *RuleColor(void) { return [UIColor colorWithRed:.55 green:.85 blue:.9 alpha:.35]; }

static UIImage *AppIcon(NSString *bid, CGFloat side) {
    UIImage *img = nil;
    if (bid.length && [UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)])
        img = [UIImage _applicationIconImageForBundleIdentifier:bid format:0 scale:UIScreen.mainScreen.scale];
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *c) {
        CGRect rect = CGRectMake(0, 0, side, side);
        [[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:side * 0.225] addClip];
        if (img) [img drawInRect:rect];
        else { [[UIColor colorWithWhite:1 alpha:.3] setFill]; UIRectFill(rect); }
    }];
}

static NSString *Ago(NSDate *d) {
    NSTimeInterval s = -[d timeIntervalSinceNow];
    if (s < 60) return NCI9L(@"now");
    NSDateComponentsFormatter *f = [NSDateComponentsFormatter new];
    f.unitsStyle = NSDateComponentsFormatterUnitsStyleAbbreviated;
    f.maximumUnitCount = 1;
    f.allowedUnits = s < 3600 ? NSCalendarUnitMinute : (s < 86400 ? NSCalendarUnitHour : NSCalendarUnitDay);
    return [NSString stringWithFormat:NCI9L(@"ago"), [f stringFromTimeInterval:s]];
}

// ---------------------------------------------------------------------------
@interface NCI9NotifCell : UITableViewCell
@property (nonatomic, strong) UILabel *titleL, *timeL, *msgL;
@end
@implementation NCI9NotifCell
- (instancetype)initWithStyle:(UITableViewCellStyle)s reuseIdentifier:(NSString *)r {
    if ((self = [super initWithStyle:s reuseIdentifier:r])) {
        self.backgroundColor = UIColor.clearColor;
        self.selectedBackgroundView = [UIView new];
        self.selectedBackgroundView.backgroundColor = [UIColor colorWithWhite:1 alpha:.15];
        _titleL = [UILabel new]; _titleL.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _timeL  = [UILabel new]; _timeL.font  = [UIFont systemFontOfSize:12];
        _timeL.textColor = [UIColor colorWithWhite:1 alpha:.55];
        _msgL   = [UILabel new]; _msgL.font   = [UIFont systemFontOfSize:15]; _msgL.numberOfLines = 3;
        for (UILabel *l in @[_titleL, _timeL, _msgL]) {
            if (l != _timeL) l.textColor = UIColor.whiteColor;
            l.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:l];
        }
        UIView *c = self.contentView;
        [NSLayoutConstraint activateConstraints:@[
            [_titleL.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:kTextX],
            [_titleL.topAnchor constraintEqualToAnchor:c.topAnchor constant:8],
            [_timeL.leadingAnchor constraintEqualToAnchor:_titleL.trailingAnchor constant:8],
            [_timeL.lastBaselineAnchor constraintEqualToAnchor:_titleL.lastBaselineAnchor],
            [_timeL.trailingAnchor constraintLessThanOrEqualToAnchor:c.trailingAnchor constant:-12],
            [_msgL.leadingAnchor constraintEqualToAnchor:_titleL.leadingAnchor],
            [_msgL.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-12],
            [_msgL.topAnchor constraintEqualToAnchor:_titleL.bottomAnchor constant:1],
            [_msgL.bottomAnchor constraintEqualToAnchor:c.bottomAnchor constant:-9],
        ]];
        [_titleL setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    }
    return self;
}
@end

// ---------------------------------------------------------------------------
@interface NCI9ViewController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation NCI9ViewController {
    UIVisualEffectView *_blur; UIView *_tintOverlay;
    UIButton *_btnToday, *_btnNotifs; UIView *_selBG, *_segBox, *_rule;
    UIScrollView *_today; UITableView *_table; UILabel *_emptyL;
    UIButton *_handle; NSInteger _tab;
    NSArray<NSString *> *_bundles; NSDictionary<NSString *, NSArray<NCI9Item *> *> *_groups;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    _blur.frame = self.view.bounds; _blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_blur];
    _tintOverlay = [[UIView alloc] initWithFrame:self.view.bounds];
    _tintOverlay.backgroundColor = [UIColor colorWithWhite:0 alpha:.25];
    _tintOverlay.autoresizingMask = _blur.autoresizingMask;
    [self.view addSubview:_tintOverlay];

    [self buildSegment]; [self buildToday]; [self buildTable]; [self buildHandle];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload) name:NCI9StoreDidChange object:nil];
    [self selectTabIndex:0];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (BOOL)prefersStatusBarHidden { return NO; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

// ---- Segment ----
- (void)buildSegment {
    CGFloat w = self.view.bounds.size.width - 2 * kSegX;
    _segBox = [[UIView alloc] initWithFrame:CGRectMake(kSegX, kSegY, w, kSegH)];
    _segBox.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _segBox.layer.cornerRadius = 4; _segBox.layer.borderWidth = 1; _segBox.clipsToBounds = YES;
    _segBox.layer.borderColor = [UIColor colorWithWhite:1 alpha:.4].CGColor;
    [self.view addSubview:_segBox];

    _selBG = [UIView new]; _selBG.backgroundColor = Tint(); [_segBox addSubview:_selBG];
    _btnToday  = [self segButton:NCI9L(@"today") tag:0];
    _btnNotifs = [self segButton:NCI9L(@"notifs") tag:1];
    _rule = [[UIView alloc] initWithFrame:CGRectMake(0, kRuleY, self.view.bounds.size.width, 1 / UIScreen.mainScreen.scale)];
    _rule.backgroundColor = RuleColor(); _rule.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:_rule];
}
- (UIButton *)segButton:(NSString *)t tag:(NSInteger)tag {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom]; b.tag = tag;
    [b setTitle:t forState:UIControlStateNormal]; b.titleLabel.font = [UIFont systemFontOfSize:17];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [b addTarget:self action:@selector(segTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_segBox addSubview:b]; return b;
}
- (void)segTapped:(UIButton *)b { [self selectTabIndex:b.tag]; }
- (void)selectTabIndex:(NSInteger)i {
    _tab = i;
    _today.hidden = (i != 0); _table.hidden = (i != 1);
    [self reload]; [self.view setNeedsLayout];
    [UIView animateWithDuration:.2 animations:^{ [self layoutSegment]; }];
}
- (void)layoutSegment {
    CGFloat w = _segBox.bounds.size.width / 2, h = _segBox.bounds.size.height;
    _btnToday.frame = CGRectMake(0, 0, w, h); _btnNotifs.frame = CGRectMake(w, 0, w, h);
    _selBG.frame = CGRectMake(_tab * w, 0, w, h);
    [_btnToday setTitleColor:_tab == 0 ? UIColor.blackColor : UIColor.whiteColor forState:UIControlStateNormal];
    [_btnNotifs setTitleColor:_tab == 1 ? UIColor.blackColor : UIColor.whiteColor forState:UIControlStateNormal];
}

// ---- Today ----
- (void)buildToday {
    _today = [UIScrollView new]; _today.alwaysBounceVertical = YES;
    [self.view addSubview:_today];
}
- (UIView *)sectionBand:(NSString *)name icon:(UIImage *)icon width:(CGFloat)w y:(CGFloat)y {
    UIView *band = [[UIView alloc] initWithFrame:CGRectMake(0, y, w, kSectionH)];
    band.backgroundColor = BandColor();
    UIImageView *iv = [[UIImageView alloc] initWithImage:icon];
    iv.frame = CGRectMake(17, (kSectionH - 20) / 2, 20, 20); [band addSubview:iv];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(kTextX, 0, w - kTextX - 50, kSectionH)];
    l.text = name; l.font = [UIFont systemFontOfSize:17]; l.textColor = [UIColor colorWithWhite:1 alpha:.8];
    [band addSubview:l]; return band;
}
- (void)rebuildToday {
    for (UIView *v in [_today.subviews copy]) [v removeFromSuperview];
    CGFloat w = self.view.bounds.size.width, y = 22;

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"EEEEMMMMd" options:0 locale:NSLocale.currentLocale];
    NSString *full = [df stringFromDate:[NSDate date]];
    NSArray *parts = [full componentsSeparatedByString:@" "];
    NSString *text = parts.count >= 2 ? [NSString stringWithFormat:@"%@\n%@", parts[0], [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@" "]] : full;
    UILabel *date = [[UILabel alloc] initWithFrame:CGRectMake(kTextX, y, w - kTextX - 16, 84)];
    date.numberOfLines = 2; date.textColor = UIColor.whiteColor;
    date.font = [UIFont systemFontOfSize:36 weight:UIFontWeightLight];
    date.text = text; [_today addSubview:date]; y += 100;

    // Widget Batteries (iPhone). Watch / AirPods : phase 2 via BatteryCenter.
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    float lvl = UIDevice.currentDevice.batteryLevel; int pct = lvl < 0 ? 0 : (int)roundf(lvl * 100);
    [_today addSubview:[self sectionBand:NCI9L(@"batteries") icon:AppIcon(@"", 20) width:w y:y]]; y += kSectionH;
    UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(kTextX, y, 160, 44)];
    name.text = NCI9L(@"iphone"); name.textColor = UIColor.whiteColor; name.font = [UIFont systemFontOfSize:17];
    [_today addSubview:name];
    UILabel *pc = [[UILabel alloc] initWithFrame:CGRectMake(w - 130, y, 70, 44)];
    pc.text = [NSString stringWithFormat:@"%d%%", pct]; pc.textAlignment = NSTextAlignmentRight;
    pc.textColor = UIColor.whiteColor; pc.font = [UIFont systemFontOfSize:17]; [_today addSubview:pc];
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(w - 50, y + 16, 36, 12)];
    bar.layer.cornerRadius = 3; bar.layer.borderWidth = 1; bar.layer.borderColor = UIColor.whiteColor.CGColor;
    UIView *fill = [[UIView alloc] initWithFrame:CGRectMake(1.5, 1.5, 33 * pct / 100.0, 9)];
    fill.backgroundColor = pct > 20 ? [UIColor colorWithRed:.3 green:.85 blue:.4 alpha:1] : UIColor.redColor;
    fill.layer.cornerRadius = 2; [bar addSubview:fill]; [_today addSubview:bar]; y += 44;
    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(kTextX, y, w - kTextX, 1 / UIScreen.mainScreen.scale)];
    sep.backgroundColor = RuleColor(); [_today addSubview:sep]; y += 40;

    // Filet + bouton Edit (image 1)
    UIView *top = [[UIView alloc] initWithFrame:CGRectMake(0, y, w, 1 / UIScreen.mainScreen.scale)];
    top.backgroundColor = RuleColor(); [_today addSubview:top]; y += 27;
    UIButton *edit = [UIButton buttonWithType:UIButtonTypeCustom];
    edit.frame = CGRectMake((w - 223) / 2, y, 223, 28);
    edit.backgroundColor = [UIColor colorWithRed:.35 green:.75 blue:.85 alpha:.8];
    edit.layer.cornerRadius = 4; edit.titleLabel.font = [UIFont systemFontOfSize:17];
    [edit setTitle:NCI9L(@"edit") forState:UIControlStateNormal];
    [edit setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
    [edit addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
    [_today addSubview:edit]; y += 60;
    _today.contentSize = CGSizeMake(w, y);
}
- (void)openSettings {
    // TODO : ouvrir le panneau Réglages (PreferenceLoader) : prefs:root=NCNine
    NSURL *u = [NSURL URLWithString:@"prefs:root=NCNine"];
    [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
    if (self.requestDismiss) self.requestDismiss();
}

// ---- Notifications ----
- (void)buildTable {
    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.backgroundColor = UIColor.clearColor; _table.dataSource = self; _table.delegate = self;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.rowHeight = UITableViewAutomaticDimension; _table.estimatedRowHeight = 60;
    _table.sectionHeaderHeight = kSectionH;
    [_table registerClass:NCI9NotifCell.class forCellReuseIdentifier:@"c"];
    [self.view addSubview:_table];
    _emptyL = [UILabel new]; _emptyL.text = NCI9L(@"none"); _emptyL.textColor = [UIColor colorWithWhite:1 alpha:.6];
    _emptyL.font = [UIFont systemFontOfSize:20]; _emptyL.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_emptyL];
}
- (void)reload {
    NSMutableArray *order = [NSMutableArray new]; NSMutableDictionary *g = [NSMutableDictionary new];
    for (NCI9Item *it in NCI9Store.shared.items) {
        if (!g[it.bundleID]) { g[it.bundleID] = [NSMutableArray new]; [order addObject:it.bundleID]; }
        [g[it.bundleID] addObject:it];
    }
    _bundles = order; _groups = g;
    [_table reloadData];
    _emptyL.hidden = (_tab != 1) || order.count > 0;
    if (_tab == 0) [self rebuildToday];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return _bundles.count; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return _groups[_bundles[s]].count; }
- (UIView *)tableView:(UITableView *)t viewForHeaderInSection:(NSInteger)s {
    NSArray *items = _groups[_bundles[s]]; NCI9Item *first = items.firstObject;
    CGFloat w = t.bounds.size.width;
    UIView *band = [self sectionBand:first.appName icon:AppIcon(first.bundleID, 20) width:w y:0];
    UIButton *x = [UIButton buttonWithType:UIButtonTypeCustom]; x.tag = s;
    x.frame = CGRectMake(w - 44, 0, 44, kSectionH);
    UIView *circle = [[UIView alloc] initWithFrame:CGRectMake(12, 5, 22, 22)];
    circle.userInteractionEnabled = NO; circle.layer.cornerRadius = 11;
    circle.backgroundColor = [UIColor colorWithWhite:1 alpha:.3];
    UILabel *glyph = [[UILabel alloc] initWithFrame:circle.bounds]; glyph.text = @"×";
    glyph.textAlignment = NSTextAlignmentCenter; glyph.textColor = UIColor.whiteColor;
    glyph.font = [UIFont systemFontOfSize:18]; [circle addSubview:glyph]; [x addSubview:circle];
    [x addTarget:self action:@selector(clearSection:) forControlEvents:UIControlEventTouchUpInside];
    [band addSubview:x]; return band;
}
- (void)clearSection:(UIButton *)b { [NCI9Store.shared removeAllForBundleID:_bundles[b.tag]]; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    NCI9NotifCell *c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    NCI9Item *it = _groups[_bundles[ip.section]][ip.row];
    c.titleL.text = it.title; c.timeL.text = Ago(it.date); c.msgL.text = it.message;
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NCI9Item *it = _groups[_bundles[ip.section]][ip.row];
    [NCI9Store.shared removeItem:it];
    if (self.requestDismiss) self.requestDismiss();
    id app = UIApplication.sharedApplication;
    if (it.bundleID.length && [app respondsToSelector:@selector(launchApplicationWithIdentifier:suspended:)])
        [(SpringBoard *)app launchApplicationWithIdentifier:it.bundleID suspended:NO];
}
- (UITableViewCellEditingStyle)tableView:(UITableView *)t editingStyleForRowAtIndexPath:(NSIndexPath *)ip { return UITableViewCellEditingStyleDelete; }
- (void)tableView:(UITableView *)t commitEditingStyle:(UITableViewCellEditingStyle)s forRowAtIndexPath:(NSIndexPath *)ip {
    [NCI9Store.shared removeItem:_groups[_bundles[ip.section]][ip.row]];
}

// ---- Poignée ----
- (void)buildHandle {
    _handle = [UIButton buttonWithType:UIButtonTypeCustom];
    [_handle addTarget:self action:@selector(handleTapped) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.view addGestureRecognizer:pan];   // glisser vers le haut n'importe où = fermer
    CAShapeLayer *chev = [CAShapeLayer layer]; UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(0, 7)]; [p addLineToPoint:CGPointMake(17.5, 1)]; [p addLineToPoint:CGPointMake(35, 7)];
    chev.path = p.CGPath; chev.fillColor = nil; chev.lineWidth = 5; chev.lineCap = kCALineCapRound; chev.lineJoin = kCALineJoinRound;
    chev.strokeColor = [UIColor colorWithRed:.45 green:.7 blue:.8 alpha:.85].CGColor;
    chev.frame = CGRectMake(0, 0, 35, 9); chev.name = @"chev";
    [_handle.layer addSublayer:chev];
    [self.view addSubview:_handle];
}
- (void)handleTapped { if (self.requestDismiss) self.requestDismiss(); }
- (void)handlePan:(UIPanGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    CGPoint v = [g velocityInView:self.view], t = [g translationInView:self.view];
    if (v.y < -300 || t.y < -80) { if (self.requestDismiss) self.requestDismiss(); }
}

// ---- Layout ----
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    CGFloat top = kRuleY + 1, bottom = h - kHandleH;
    _today.frame = CGRectMake(0, top, w, bottom - top);
    _table.frame = _today.frame;
    _emptyL.frame = CGRectMake(0, top, w, bottom - top);
    _handle.frame = CGRectMake(0, bottom, w, kHandleH);
    CALayer *chev = nil; for (CALayer *l in _handle.layer.sublayers) if ([l.name isEqual:@"chev"]) chev = l;
    chev.position = CGPointMake(w / 2, kHandleH / 2);
    [self layoutSegment];
    if (_tab == 0 && _today.subviews.count == 0) [self rebuildToday];
}
@end
