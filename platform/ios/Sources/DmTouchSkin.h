// 触控面 PNG 皮肤（安卓 ControlSkin 同款 key 集）：从 bundle Gen/skin/ 加载（optional 资源，
// 出包时用户提供——公开源码树不含游戏衍生位图，与 Gen/romfs 同纪律）。缺失全部降级（矢量/文字）。
// | Touch-skin PNG loader (Android ControlSkin keys): loads from bundle Gen/skin/,
// | an optional user-provided resource folder; every lookup degrades gracefully.
#import <UIKit/UIKit.h>

@interface DmTouchSkin : NSObject
+ (instancetype)shared;
// 按键名取图（key = ControlSkin 命名：portal/evade/pickup/inventory/menu/potion/skill1..6/
// digit0..9/duration_fill/duration_yellow/duration_empty/duration_frame_top/duration_frame_btm/
// buff_indicator/cooldown_cover/lock/selected）；无 Gen/skin 或无该文件 → nil
- (UIImage *)image:(NSString *)key;
// 数字位图串（number()）：value 逐字符取 digitN，返回排好的 UIImage（透明底）；失败 nil
- (UIImage *)numberImage:(NSInteger)value height:(CGFloat)height;
@end
