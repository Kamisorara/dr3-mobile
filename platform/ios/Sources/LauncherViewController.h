#import <UIKit/UIKit.h>

// Settings are selected before any Metal device or guest preload is created.
// Display mode: 0 = 标准 16:9（letterbox）, 1 = 填充（放大裁边）, 2 = 适配（参数槽按屏幕比例原生渲染）.
@interface LauncherViewController : UIViewController
@property (copy) void (^onPlay)(NSInteger mode, BOOL hud, BOOL metalfx, BOOL lan);
- (instancetype)initWithWideAvailable:(BOOL)wide lanAvailable:(BOOL)lan ready:(BOOL)ready reason:(NSString *)reason;
@end
