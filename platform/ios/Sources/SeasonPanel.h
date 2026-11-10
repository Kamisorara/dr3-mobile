// 赛季设置面板（kb/20 §6 v1）：程序化 UIKit 浮层，写 $DM_SAVE/dm-season.tsv（原子替换），宿主 1Hz 重载。
// 轮换公式与 hle_season.c 同式：整月差（日不计，每月 1 号换季）+ 1，S1 = origin 当月（缺省 2026-11）。
#import <UIKit/UIKit.h>

@interface SeasonPanel : UIView
+ (void)presentInView:(UIView *)root;   // 盖住 root（游戏触控面/窗口根），点背景关闭
@end
