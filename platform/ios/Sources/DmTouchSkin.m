#import "DmTouchSkin.h"

@implementation DmTouchSkin {
    NSMutableDictionary<NSString *, UIImage *> *_cache;
    NSString *_dir;
}
+ (instancetype)shared {
    static DmTouchSkin *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[DmTouchSkin alloc] init]; });
    return s;
}
- (instancetype)init {
    if ((self = [super init])) {
        _cache = [NSMutableDictionary new];
        // 资源以 folder reference 打进包根 Gen/skin/（project.yml optional；没出素材就没有目录）
        _dir = [NSBundle.mainBundle pathForResource:@"skin" ofType:nil inDirectory:@"Gen"];
        if (_dir) NSLog(@"[dm] 触控皮肤目录 %@", _dir);
        else NSLog(@"[dm] 无 Gen/skin 触控皮肤（矢量/文字降级）");
    }
    return self;
}
- (UIImage *)image:(NSString *)key {
    if (!_dir || key.length == 0) return nil;
    UIImage *img = _cache[key];
    if (img) return img;
    img = [UIImage imageWithContentsOfFile:[_dir stringByAppendingPathComponent:[key stringByAppendingPathExtension:@"png"]]];
    if (img) {
        img = [img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        _cache[key] = img;
    }
    return img;
}
- (UIImage *)numberImage:(NSInteger)value height:(CGFloat)height {
    if (value < 0 || height <= 0) return nil;
    NSString *s = [NSString stringWithFormat:@"%ld", (long)value];
    NSMutableArray<UIImage *> *digits = [NSMutableArray new];
    CGFloat wsum = 0;
    for (NSUInteger i = 0; i < s.length; i++) {
        UIImage *d = [self image:[NSString stringWithFormat:@"digit%@", [s substringWithRange:NSMakeRange(i, 1)]]];
        if (!d) return nil;   // 任一数字缺图 → 整体降级
        CGFloat w = d.size.width * height / d.size.height;
        [digits addObject:d];
        wsum += w + (i + 1 < s.length ? 1 : 0);   // 字间距 = unit（安卓 SCV:697-720 取 1pt 近似）
    }
    if (wsum <= 0) return nil;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat new];
    fmt.scale = UIScreen.mainScreen.scale ?: 2;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(wsum, height) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGFloat x = 0;
        for (UIImage *d in digits) {
            CGFloat w = d.size.width * height / d.size.height;
            [d drawInRect:CGRectMake(x, 0, w, height)];
            x += w + 1;
        }
    }];
}
@end
