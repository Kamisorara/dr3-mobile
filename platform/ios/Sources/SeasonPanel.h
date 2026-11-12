// 赛季面板（kb/20 §6 v3）= 纯展示：程序化 UIKit 浮层，无任何可编辑项、不写配置。
// 赛季不可关闭 + S1 写死 2026-11-01、月更轮换自动换季（2026-11-12 定案；dm-season.tsv 整个废除）。
// 轮换公式与 hle_season.c 同式：整月差（日不计，每月 1 号换季）+ 1，S1 = 2026-11 当月。
#import <UIKit/UIKit.h>

@interface SeasonPanel : UIView
+ (void)presentInView:(UIView *)root;   // 盖住 root（游戏触控面/窗口根），点背景关闭
@end
