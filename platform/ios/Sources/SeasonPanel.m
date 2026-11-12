#import "SeasonPanel.h"
#import <UIKit/UIKit.h>
#include <stdio.h>
#include <sys/stat.h>

// 与 hle_season.c 同式的轮换日历（整月差，日不计；今天早于 origin 时 clamp 到 S1）
static int dm_season_number(NSInteger oy, NSInteger om) {
    NSCalendar *c = NSCalendar.currentCalendar;
    NSDateComponents *now = [c components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:[NSDate date]];
    NSInteger diff = (now.year - oy) * 12 + (now.month - om);
    return (int)MAX(diff, 0) + 1;
}

// 赛季不可关闭（用户定案 2026-11-12）：面板无总开关，宿主侧 enabled 硬线 1；
// 唯一可配 = 轮换起始日（月更轮换锚点，当月=S1）。旧 dm-season.tsv 里的 enabled/mode/season 键两侧行都忽略。
@implementation SeasonPanel {
    UITextField *_originField;   // YYYY-MM-DD（取年月；当日 = S1）
    UILabel *_effective;
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        [self buildCard];
        [self loadConfig];
    }
    return self;
}

- (void)buildCard {
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 460, 210)];
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

    _effective = [[UILabel alloc] initWithFrame:CGRectMake(24, 52, 412, 22)];
    _effective.tag = 101;
    _effective.textColor = [UIColor colorWithWhite:0.62 alpha:1]; _effective.font = [UIFont systemFontOfSize:13];
    [card addSubview:_effective];

    [self rowLabel:@"轮换起始日" y:96 card:card];
    _originField = [self field:CGRectMake(210, 92, 130, 34) card:card keyboard:UIKeyboardTypeNumbersAndPunctuation];
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(348, 94, 90, 30)];
    hint.text = @"当月=S1"; hint.font = [UIFont systemFontOfSize:11];
    hint.textColor = [UIColor colorWithWhite:0.5 alpha:1];
    [card addSubview:hint];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(24, 146, 412, 40);
    close.layer.cornerRadius = 8;
    close.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    close.tintColor = UIColor.whiteColor;
    close.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [close setTitle:@"保存并关闭" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(saveClose) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:close];
}

- (void)rowLabel:(NSString *)s y:(CGFloat)y card:(UIView *)card {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(24, y, 170, 26)];
    l.text = s; l.textColor = [UIColor colorWithWhite:0.9 alpha:1]; l.font = [UIFont systemFontOfSize:15];
    [card addSubview:l];
}

- (UITextField *)field:(CGRect)r card:(UIView *)card keyboard:(UIKeyboardType)kb {
    UITextField *t = [[UITextField alloc] initWithFrame:r];
    t.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1];
    t.textColor = UIColor.whiteColor; t.keyboardType = kb;
    t.layer.cornerRadius = 6;
    t.textAlignment = NSTextAlignmentCenter;
    t.delegate = self;
    [card addSubview:t];
    return t;
}

- (void)loadConfig {
    // 缺省 = 轮换锚点 2026-11-01（S1）；enabled/mode/season 键已废除（旧文件里的残留一律忽略）
    _originField.text = @"2026-11-01";
    NSString *sv = [[[NSProcessInfo processInfo] environment] objectForKey:@"DM_SAVE"];
    if (!sv) return;
    NSString *path = [sv stringByAppendingPathComponent:@"dm-season.tsv"];
    NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!s) return;
    for (NSString *ln in [s componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSArray *kv = [ln componentsSeparatedByString:@"\t"];
        if (kv.count < 2) continue;
        NSString *k = kv[0], *v = kv[1];
        if ([k isEqualToString:@"origin"]) _originField.text = v;
    }
}

- (void)refresh {
    NSInteger oy = 2026, om = 11;
    NSScanner *sc = [NSScanner scannerWithString:_originField.text];
    [sc scanInteger:&oy]; [sc setCharactersToBeSkipped:[NSCharacterSet characterSetWithCharactersInString:@"-/."]];
    [sc scanInteger:&om];
    int s = dm_season_number(oy, om);
    UILabel *cur = (UILabel *)[self viewWithTag:100];
    cur.text = [NSString stringWithFormat:@"当前生效 S%d", s];
    _effective.text = [NSString stringWithFormat:@"月更轮换（不可关闭）：每月 1 号新赛季（%04ld-%02ld 当月 = S1）", (long)oy, (long)om];
}

- (void)textFieldDidEndEditing:(UITextField *)textField { [self refresh]; }

- (void)saveClose {
    NSString *sv = [[[NSProcessInfo processInfo] environment] objectForKey:@"DM_SAVE"];
    if (sv) {
        NSString *path = [sv stringByAppendingPathComponent:@"dm-season.tsv"];
        NSString *tmp = [path stringByAppendingString:@".tmp"];
        NSString *body = [NSString stringWithFormat:
            @"origin\t%@\n",
            _originField.text.length ? _originField.text : @"2026-11-01"];
        if ([body writeToFile:tmp atomically:YES encoding:NSUTF8StringEncoding error:nil])
            rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation);   // 原子替换；宿主 1Hz 重载
    }
    [self removeFromSuperview];
}

- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    [self endEditing:YES];
    for (UITouch *t in ts)
        if (t.view == self) { [self saveClose]; return; }   // 点卡片外 = 关闭（不保存）
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField { [textField resignFirstResponder]; [self refresh]; return YES; }

+ (void)presentInView:(UIView *)root {
    for (id v in root.subviews) if ([v isKindOfClass:self]) [v removeFromSuperview];   // 幂等
    SeasonPanel *p = [[SeasonPanel alloc] initWithFrame:root.bounds];
    [root addSubview:p];
    [p refresh];
}
@end
