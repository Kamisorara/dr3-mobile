// 分享日志（kb/21 日志规范的一环）：把 Documents 下的运行日志用系统分享面板发出去。
// 两处入口：游戏内 DmGamepad 顶排「享」键（in_game=1：先 crash_dump_now 把当前全部线程现场
// 同步写进 log.txt 再分享 = "当前运行到现在"的最完整快照）；启动界面「分享日志」小按钮
// （in_game=0：游戏未跑，直接分享现有文件——崩溃重启后交上一场现场的主路径）。
#import <UIKit/UIKit.h>

void dm_log_share(UIView *source, int in_game);
