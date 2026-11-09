// 赛季轮换设置面板（kb/18 A 路线：壳侧自绘；kb/17 E 层的壳侧入口）。
// 写 $DM_SAVE/dm-season.tsv（旁路存储，不碰官方偏好——kb/18 §3.3），宿主 hle_season.c 1Hz 重载。
// | Season rotation settings panel (shell-drawn per kb/18 route A). Writes
// | $DM_SAVE/dm-season.tsv; the host's hle_season.c reloads it at 1 Hz.
#import <UIKit/UIKit.h>

@interface SeasonPanel : UIView
// 以全屏浮层显示在 parent 之上（首次创建后复用；背景点按关闭）。parent = 触控面视图。
+ (void)presentInView:(UIView *)parent;
@end
