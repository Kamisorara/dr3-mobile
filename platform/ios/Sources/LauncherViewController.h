#import <UIKit/UIKit.h>

// Settings are selected before any Metal device or guest preload is created.
// Display mode: 0 = 标准 16:9（letterbox 适配）, 1 = 填充（放大裁边铺满非 16:9 屏幕）, 2 = 宽屏（1568×720 贴满 iPhone 类屏幕）.
@interface LauncherViewController : UIViewController
@property (copy) void (^onPlay)(NSInteger mode, BOOL hud, BOOL metalfx, BOOL lan);
- (instancetype)initWithWideAvailable:(BOOL)wide lanAvailable:(BOOL)lan ready:(BOOL)ready reason:(NSString *)reason;
@end
