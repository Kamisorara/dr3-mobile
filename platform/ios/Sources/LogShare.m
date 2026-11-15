#import "LogShare.h"
#import <UIKit/UIKit.h>

// 宿主符号（dm.h:89）：同步把全部线程现场写进 stderr（= Documents/log.txt，行缓冲）再返回。
// 同进程直调的先例：main.m 的 boot_thread 调 dm_main。游戏运行中调用会短暂暂停 guest 线程（smoke
// 的 no-progress watchdog 同机制，几十毫秒），换"分享 = 顺带附送线程转储"，排障价值极高。
void crash_dump_now(const char *why);

static NSString *doc_path(NSString *name) {
    static NSString *doc;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]; });
    return [doc stringByAppendingPathComponent:name];
}

void dm_log_share(UIView *source, int in_game) {
    fflush(stderr);                                        // stderr 是行缓冲（main.m freopen + _IOLBF），落盘尾行
    if (in_game) crash_dump_now("分享日志");               // 当前全部线程现场 → log.txt 末尾
    dispatch_async(dispatch_get_main_queue(), ^{          // present 模式照 front_save_failed（front_ios.m）
        UIViewController *vc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) vc = w.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (!vc) return;
        // 附件：存在即加。诊断大文件（performance.tsv / controller*.jsonl）不带——它们是排查期定向开关的产物。
        NSMutableArray *items = [NSMutableArray array];
        for (NSString *n in @[@"log.txt", @"log.prev.txt", @"env.txt", @"webdav.log"]) {
            NSString *p = doc_path(n);
            if ([[NSFileManager defaultManager] fileExistsAtPath:p]) [items addObject:[NSURL fileURLWithPath:p]];
        }
        if (!items.count) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"没有可分享的日志 / No logs"
                                                                       message:@"Documents 下没有日志文件。No log files found."
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [vc presentViewController:a animated:YES completion:nil];
            return;
        }
        UIActivityViewController *ac = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
        if (ac.popoverPresentationController) {           // iPad：不设 sourceView 直接 present 会崩
            ac.popoverPresentationController.sourceView = source ?: vc.view;
            ac.popoverPresentationController.sourceRect = (source ?: vc.view).bounds;
        }
        [vc presentViewController:ac animated:YES completion:nil];
    });
}
