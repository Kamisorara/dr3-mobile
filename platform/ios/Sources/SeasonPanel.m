#import "SeasonPanel.h"
#import <UIKit/UIKit.h>

// 与 hle_season.c 同式的轮换日历（整月差，日不计；今天早于 origin 时 clamp 到 S1）
static int dm_season_number(NSInteger oy, NSInteger om) {
    NSCalendar *c = NSCalendar.currentCalendar;
    NSDateComponents *now = [c components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:[NSDate date]];
    NSInteger diff = (now.year - oy) * 12 + (now.month - om);
    return (int)MAX(diff, 0) + 1;
}

// 赛季面板 = 纯展示（用户定案 2026-11-12）：S1 写死 2026-11-01、月更轮换、不可关闭，无任何可编辑项。
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
    UILabel *cur = (UILabel *)[self viewWithTag:100];
    cur.text = [NSString stringWithFormat:@"当前生效 S%d", s];
    UILabel *desc = (UILabel *)[self viewWithTag:101];
    desc.text = @"自动轮换（不可关闭）：每月 1 号新赛季\n2026-11 当月 = S1，已写死";
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
