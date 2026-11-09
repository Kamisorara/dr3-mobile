// 赛季轮换设置面板实现（SeasonPanel.h）。
// 值 → $DM_SAVE/dm-season.tsv（TSV，tab 分隔；与 hle_season.c config_load 的解析一一对应）：
//   enabled\t0|1 / mode\tfixed|rotate / season\t<N> / days\t<N> / origin\tYYYY-MM-DD
// 轮换口径与宿主一致：civil 日（UTC 天数差），S14–S27 循环；"当前生效"就地用同一公式显示。
#import "SeasonPanel.h"

static NSInteger const kSeasonLo = 14, kSeasonHi = 27;

// civil 日数（Howard Hinnant days_from_civil，与 hle_season.c 同式）
static long daysFromCivil(int y, int m, int d) {
    y -= m <= 2;
    long era = (y >= 0 ? y : y - 399) / 400;
    unsigned yoe = (unsigned)(y - era * 400);
    unsigned doy = (153u * (unsigned)(m + (m > 2 ? -3 : 9)) + 2) / 5 + (unsigned)d - 1;
    unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097L + (long)doe - 719468L;
}

@interface SeasonPanel ()
@end

@implementation SeasonPanel {
    UISwitch *_enabled;
    UISegmentedControl *_mode;
    UIStepper *_season;
    UILabel *_seasonLab;
    UIStepper *_days;
    UILabel *_daysLab;
    UIDatePicker *_origin;
    UILabel *_effLab;
    UIView *_rotateRows;      // 轮换两行（周期/起始日）随模式显隐
    BOOL _loading;            // 回填期间不写文件
}
+ (NSString *)configPath {
    const char *sv = getenv("DM_SAVE");
    NSString *dir = sv ? [NSString stringWithUTF8String:sv]
                       : [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"save"];
    return [dir stringByAppendingPathComponent:@"dm-season.tsv"];
}

// ---- 配置读写 ----
- (void)loadConfig {
    _loading = YES;
    NSString *txt = [NSString stringWithContentsOfFile:[SeasonPanel configPath] encoding:NSUTF8StringEncoding error:nil];
    BOOL enabled = NO, rotate = NO;
    NSInteger season = kSeasonHi, days = 30;
    NSDate *origin = [self today];
    for (NSString *raw in [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSRange t = [raw rangeOfString:@"\t"];
        if (t.location == NSNotFound) continue;
        NSString *key = [raw substringToIndex:t.location], *val = [raw substringFromIndex:t.location + 1];
        if ([key isEqualToString:@"enabled"]) enabled = [val isEqualToString:@"1"];
        else if ([key isEqualToString:@"mode"]) rotate = [val isEqualToString:@"rotate"];
        else if ([key isEqualToString:@"season"]) season = val.integerValue;
        else if ([key isEqualToString:@"days"]) days = val.integerValue;
        else if ([key isEqualToString:@"origin"]) {
            NSDateFormatter *df = [NSDateFormatter new];
            df.dateFormat = @"yyyy-MM-dd"; df.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
            df.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
            NSDate *d = [df dateFromString:val];
            if (d) origin = d;
        }
    }
    _enabled.on = enabled;
    _mode.selectedSegmentIndex = rotate ? 1 : 0;
    _season.value = MIN(MAX(season, kSeasonLo), kSeasonHi);
    _days.value = MIN(MAX(days, 1), 365);
    _origin.date = origin;
    _loading = NO;
    [self refreshLabels];
}

- (NSDate *)today {   // 今天（按本地日历的 y/m/d → UTC 零点，取整到 civil 日）
    NSDateComponents *c = [NSCalendar.currentCalendar componentsInTimeZone:NSCalendar.currentCalendar.timeZone fromDate:[NSDate date]];
    NSDateComponents *d = [NSDateComponents new];
    d.year = c.year; d.month = c.month; d.day = c.day;
    NSCalendar *g = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    g.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    return [g dateFromComponents:d];
}

- (NSInteger)effectiveSeason {
    NSInteger base = (NSInteger)_season.value;
    if (_mode.selectedSegmentIndex == 0) return base;
    NSCalendar *g = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    g.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSDateComponents *oc = [g components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:_origin.date];
    NSDateComponents *tc = [g components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:[self today]];
    long o = daysFromCivil((int)oc.year, (int)oc.month, (int)oc.day);
    long today = daysFromCivil((int)tc.year, (int)tc.month, (int)tc.day);
    long idx = MAX(0, (today - o) / MAX(1, (NSInteger)_days.value));
    return kSeasonLo + (base - kSeasonLo + idx) % (kSeasonHi - kSeasonLo + 1);
}

- (void)saveConfig {
    if (_loading) return;
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd"; df.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    df.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSString *text = [NSString stringWithFormat:
        @"# dm-season 轮换配置（SeasonPanel 写；宿主 hle_season.c 1Hz 重载）\n"
        "enabled\t%d\nmode\t%@\nseason\t%ld\ndays\t%ld\norigin\t%@\n",
        _enabled.on ? 1 : 0,
        _mode.selectedSegmentIndex == 1 ? @"rotate" : @"fixed",
        (long)_season.value, (long)_days.value,
        [df stringFromDate:_origin.date]];
    NSString *path = [SeasonPanel configPath], *tmp = [path stringByAppendingString:@".tmp"];
    if (![text writeToFile:tmp atomically:YES encoding:NSUTF8StringEncoding error:nil]) return;
    rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation);   // 原子替换（TouchLayoutStore 同纪律）
    [self refreshLabels];
}

- (void)refreshLabels {
    _seasonLab.text = [NSString stringWithFormat:@"S%ld", (long)_season.value];
    _daysLab.text = [NSString stringWithFormat:@"%ld 天", (long)_days.value];
    BOOL rotate = _mode.selectedSegmentIndex == 1;
    _rotateRows.hidden = !rotate;
    _effLab.text = [NSString stringWithFormat:@"当前生效：S%ld（%@）", (long)[self effectiveSeason],
                    _enabled.on ? (rotate ? @"轮换" : @"固定") : @"关（原版行为）"];
}

// ---- UI ----
- (UILabel *)row:(NSString *)title into:(UIStackView *)v {
    UILabel *l = [UILabel new];
    l.text = title; l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:15];
    [l setContentCompressionResistancePriority:751 forAxis:UILayoutConstraintAxisHorizontal];
    [v addArrangedSubview:l];
    return l;
}
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        UIView *card = [UIView new];
        card.backgroundColor = [UIColor colorWithWhite:0.09 alpha:0.97];
        card.layer.cornerRadius = 14;
        card.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:card];
        UIStackView *stack = [UIStackView new];
        stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 14;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:stack];
        NSLayoutConstraint *wFix = [card.widthAnchor constraintEqualToConstant:340];
        wFix.priority = 999;   // 窄屏让位给 ≤宽-48，不留不可满足冲突
        [NSLayoutConstraint activateConstraints:@[
            [card.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [card.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [card.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor constant:-48],
            wFix,
            [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:20],
            [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20],
            [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
            [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        ]];
        UILabel *title = [UILabel new];
        title.text = @"赛季轮换"; title.textColor = UIColor.whiteColor;
        title.font = [UIFont boldSystemFontOfSize:18]; title.textAlignment = NSTextAlignmentCenter;
        [stack addArrangedSubview:title];

        UIStackView *rEn = [self rowStack:stack];
        [self row:@"总开关" into:rEn];
        _enabled = [UISwitch new];
        _enabled.onTintColor = [UIColor colorWithWhite:0.35 alpha:1];
        [_enabled addTarget:self action:@selector(saveConfig) forControlEvents:UIControlEventValueChanged];
        [rEn addArrangedSubview:_enabled];

        UIStackView *rMode = [self rowStack:stack];
        [self row:@"模式" into:rMode];
        _mode = [[UISegmentedControl alloc] initWithItems:@[@"固定", @"轮换"]];
        _mode.selectedSegmentTintColor = [UIColor colorWithWhite:0.3 alpha:1];
        [_mode setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateNormal];
        [_mode addTarget:self action:@selector(saveConfig) forControlEvents:UIControlEventValueChanged];
        [rMode addArrangedSubview:_mode];

        UIStackView *rSeason = [self rowStack:stack];
        [self row:@"赛季" into:rSeason];
        _seasonLab = [UILabel new]; _seasonLab.textColor = UIColor.whiteColor;
        _season = [[UIStepper alloc] init];
        _season.minimumValue = kSeasonLo; _season.maximumValue = kSeasonHi; _season.stepValue = 1;
        [_season addTarget:self action:@selector(saveConfig) forControlEvents:UIControlEventValueChanged];
        [rSeason addArrangedSubview:_season];
        [rSeason addArrangedSubview:_seasonLab];

        _rotateRows = [UIStackView new];
        _rotateRows.axis = UILayoutConstraintAxisVertical; _rotateRows.spacing = 14;
        [stack addArrangedSubview:_rotateRows];
        UIStackView *rDays = [self rowStack:_rotateRows];
        [self row:@"周期" into:rDays];
        _daysLab = [UILabel new]; _daysLab.textColor = UIColor.whiteColor;
        _days = [[UIStepper alloc] init];
        _days.minimumValue = 1; _days.maximumValue = 365; _days.stepValue = 1;
        [_days addTarget:self action:@selector(saveConfig) forControlEvents:UIControlEventValueChanged];
        [rDays addArrangedSubview:_days];
        [rDays addArrangedSubview:_daysLab];
        UIStackView *rOrigin = [self rowStack:_rotateRows];
        [self row:@"起始日" into:rOrigin];
        _origin = [[UIDatePicker alloc] init];
        _origin.datePickerMode = UIDatePickerModeDate;
        _origin.preferredDatePickerStyle = UIDatePickerStyleCompact;
        _origin.tintColor = UIColor.whiteColor;
        [_origin addTarget:self action:@selector(saveConfig) forControlEvents:UIControlEventValueChanged];
        [rOrigin addArrangedSubview:_origin];

        _effLab = [UILabel new];
        _effLab.textColor = [UIColor colorWithWhite:0.75 alpha:1];
        _effLab.font = [UIFont systemFontOfSize:13]; _effLab.textAlignment = NSTextAlignmentCenter;
        [stack addArrangedSubview:_effLab];
    }
    return self;
}
- (UIStackView *)rowStack:(UIStackView *)parent {
    UIStackView *r = [UIStackView new];
    r.axis = UILayoutConstraintAxisHorizontal; r.spacing = 12;
    r.alignment = UIStackViewAlignmentCenter;
    [parent addArrangedSubview:r];
    return r;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {   // 背景点按关闭
    UITouch *t = ts.anyObject;
    if (t && t.view == self) [self hide];
}
- (void)hide { [UIView animateWithDuration:0.18 animations:^{ self.alpha = 0; } completion:^(BOOL done) { if (done) self.hidden = YES; }]; }
+ (void)presentInView:(UIView *)parent {
    static SeasonPanel *panel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ panel = [[SeasonPanel alloc] initWithFrame:parent.bounds]; });
    if (!panel.superview) [parent addSubview:panel];
    panel.frame = parent.bounds;
    panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [panel loadConfig];
    panel.alpha = 0; panel.hidden = NO;
    [UIView animateWithDuration:0.18 animations:^{ panel.alpha = 1; }];
}
@end
