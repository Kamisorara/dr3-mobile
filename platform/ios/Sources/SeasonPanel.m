#import "SeasonPanel.h"
#import <UIKit/UIKit.h>

// 与 hle_season.c 同式的轮换日历（整月差，日不计；今天早于 origin 时 clamp 到 S1）
static int dm_season_number(NSInteger oy, NSInteger om) {
    NSCalendar *c = NSCalendar.currentCalendar;
    NSDateComponents *now = [c components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:[NSDate date]];
    NSInteger diff = (now.year - oy) * 12 + (now.month - om);
    return (int)MAX(diff, 0) + 1;
}

// 与 hle_season.c 同式的 12 主题表（v4，2026-11-13）：官方 S14→…→S22→S24→S25→S27 顺序循环
//（排除无 Perk 旗标的 S23/S26）；theme_idx = (S-1) mod 12。
static const int kThemeOff[12] = {14, 15, 16, 17, 18, 19, 20, 21, 22, 24, 25, 27};
static NSString *const kThemeZh[12] = {
    @"贪婪赛季", @"赫拉迪姆之赐", @"威仪赛季", @"噩梦赛季", @"三神教赛季", @"永恒冲突",
    @"禁忌档案馆", @"风暴试炼", @"往昔之影", @"虚灵记忆", @"地狱领主", @"光明的召唤",
};
static NSString *const kThemeDesc[12] = {
    @"宝藏哥布林双倍刷新", @"悬赏礼盒双倍", @"全员白送皇家气派之戒", @"全员白送噩梦遗产双戒",
    @"地面周期刷三神教法阵", @"万魔殿连杀奖励", @"卡奈魔盒三槽自由混搭", @"周期元素风暴附身",
    @"神龛召唤暗影分身 + 魔盒第 4 槽", @"21 件虚灵武器", @"7 枚灵魂碎片", @"天使坩埚圣化传奇",
};

// 赛季面板 = 纯展示（用户定案 2026-11-12）：S1 写死 2026-11-01、月更轮换、不可关闭，无任何可编辑项。
// v4（2026-11-13）：主题 = 官方 12 主题顺序循环；跨季英雄转非赛季（官方严格 rollover）。
// 面板不写任何配置；宿主侧同样写死（dm-season.tsv 整个废除）。
@implementation SeasonPanel

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        [self buildCard];
        [self refresh];
    }
    return self;
}

- (void)buildCard {
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 460, 160)];
    card.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    card.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    card.backgroundColor = [UIColor colorWithWhite:0.09 alpha:0.97];
    card.layer.cornerRadius = 14;
    card.layer.shadowOpacity = 0.5; card.layer.shadowRadius = 18;
    [self addSubview:card];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(24, 18, 200, 28)];
    title.text = @"赛季";
    title.textColor = UIColor.whiteColor; title.font = [UIFont boldSystemFontOfSize:20];
    [card addSubview:title];

    UILabel *cur = [[UILabel alloc] initWithFrame:CGRectMake(card.bounds.size.width - 200, 18, 176, 28)];
    cur.tag = 100; cur.textAlignment = NSTextAlignmentRight;
    cur.textColor = [UIColor colorWithWhite:0.85 alpha:1]; cur.font = [UIFont systemFontOfSize:15];
    [card addSubview:cur];

    UILabel *desc = [[UILabel alloc] initWithFrame:CGRectMake(24, 54, 412, 40)];
    desc.tag = 101;
    desc.numberOfLines = 2;
    desc.textColor = [UIColor colorWithWhite:0.62 alpha:1]; desc.font = [UIFont systemFontOfSize:13];
    [card addSubview:desc];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(24, 104, 412, 40);
    close.layer.cornerRadius = 8;
    close.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    close.tintColor = UIColor.whiteColor;
    close.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:close];
}

- (void)refresh {
    int s = dm_season_number(2026, 11);
    int t = (s - 1) % 12;
    UILabel *cur = (UILabel *)[self viewWithTag:100];
    cur.text = [NSString stringWithFormat:@"当前生效 S%d", s];
    UILabel *desc = (UILabel *)[self viewWithTag:101];
    desc.text = [NSString stringWithFormat:@"主题：%@（官方S%d）· %@\n每月 1 号换季（跨季英雄转非赛季）；主题自下次启动生效",
                 kThemeZh[t], kThemeOff[t], kThemeDesc[t]];
}

- (void)close { [self removeFromSuperview]; }

- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    for (UITouch *t in ts)
        if (t.view == self) { [self close]; return; }   // 点卡片外 = 关闭
}

+ (void)presentInView:(UIView *)root {
    for (id v in root.subviews) if ([v isKindOfClass:self]) [v removeFromSuperview];   // 幂等
    SeasonPanel *p = [[SeasonPanel alloc] initWithFrame:root.bounds];
    [root addSubview:p];
    [p refresh];
}
@end
