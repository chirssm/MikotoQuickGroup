// ============================================================================
//  MikotoQuickGroup —— 独立插件：在微信聊天界面加一个「快速分组」按钮
// ----------------------------------------------------------------------------
//  依赖宿主 : WeChat (com.tencent.xin) + MikotoHelper.dylib（提供 Misaka 分组能力）
//  交互约定 :
//    · 单击按钮  → 直接归入「默认分组」；若尚未设置默认，则弹出选择器，
//                  并把这次选择的结果保存为默认分组
//    · 长按按钮  → 菜单：修改默认分组 / 本次归入其他分组 / 清除默认分组
//    · 按钮标题会显示当前默认（例：分组·群聊），未设置时显示「分组」
//
//  设计原则 : 只经 Objective-C 运行时(类名 + 选择子)调用 MikotoHelper，
//             不产生任何链接依赖；全部调用做 respondsToSelector: 保护，失败静默降级。
// ============================================================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 常量与枚举

static NSString *const kPJQGDefaultKindKey = @"pjqg_default_kind";   // NSInteger，-1 = 未设置
static const void    *kPJQGActionKey      = &kPJQGActionKey;         // 关联对象 key

typedef NS_ENUM(NSInteger, PJQGKind) {
    PJQGKindGroup = 0,   // 群聊
    PJQGKindChat  = 1,   // 聊天
    PJQGKindOther = 2,   // 其他
};

static NSString *PJQGKindName(PJQGKind k) {
    switch (k) {
        case PJQGKindGroup: return @"群聊";
        case PJQGKindChat:  return @"聊天";
        case PJQGKindOther: return @"其他";
    }
    return @"未知";
}

#pragma mark - 默认分组持久化（NSUserDefaults）

static NSInteger PJQGDefaultKind(void) {
    NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kPJQGDefaultKindKey];
    return n ? n.integerValue : -1;
}

static void PJQGSetDefaultKind(NSInteger k) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (k < 0) {
        [d removeObjectForKey:kPJQGDefaultKindKey];
    } else {
        [d setInteger:k forKey:kPJQGDefaultKindKey];
    }
    [d synchronize];
}

#pragma mark - 轻量 Toast（自带，不依赖 MikotoHelper）

static void PJQGToast(UIView *host, NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = host.window;
        if (!w) {
            for (UIWindow *win in UIApplication.sharedApplication.windows) {
                if (win.isKeyWindow) { w = win; break; }
            }
        }
        if (!w) return;

        UILabel *l = [[UILabel alloc] init];
        l.text            = text;
        l.textColor       = UIColor.whiteColor;
        l.font            = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        l.textAlignment   = NSTextAlignmentCenter;
        l.numberOfLines   = 0;
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
        l.layer.cornerRadius = 10;
        l.clipsToBounds   = YES;

        CGSize max = CGSizeMake(w.bounds.size.width - 80, CGFLOAT_MAX);
        CGSize sz  = [l sizeThatFits:max];
        l.frame = CGRectMake(0, 0, sz.width + 34, sz.height + 22);
        l.center = CGPointMake(w.bounds.size.width / 2, w.bounds.size.height * 0.78);
        [w addSubview:l];

        l.alpha = 0;
        [UIView animateWithDuration:0.18 animations:^{ l.alpha = 1.0; }
                         completion:^(BOOL f) {
            [UIView animateWithDuration:0.30 delay:1.10 options:0
                             animations:^{ l.alpha = 0.0; }
                             completion:^(BOOL f2) { [l removeFromSuperview]; }];
        }];
    });
}

#pragma mark - MikotoHelper 桥接层（全部运行时解析）

// 取 Misaka 管理器单例：候选访问器逐个探测
static id PJQGMisakaManager(void) {
    Class c = NSClassFromString(@"PJMisakaManager");
    if (!c) return nil;
    NSArray *cands = @[@"sharedInstance", @"sharedManager", @"defaultManager",
                       @"manager", @"shared"];
    for (NSString *name in cands) {
        SEL s = NSSelectorFromString(name);
        if ([c respondsToSelector:s]) {
            id m = ((id (*)(id, SEL))objc_msgSend)(c, s);
            if (m) return m;
        }
    }
    return nil;
}

// 读当前会话标识
static NSString *PJQGChatId(UIViewController *vc) {
    NSArray *keys = @[@"m_nsChatName", @"m_nsRealChatUsr",
                      @"m_nsChatRoomUserName", @"chatUserName"];
    for (NSString *k in keys) {
        @try {
            id v = [vc valueForKey:k];
            if ([v isKindOfClass:NSString.class] && [v length] > 0) return v;
        } @catch (__unused NSException *e) { /* 忽略 KVC 失败 */ }
    }
    return nil;
}

// 把某个会话写入指定分组，并刷新主界面
static BOOL PJQGApply(NSString *chatId, PJQGKind kind) {
    if (chatId.length == 0) return NO;

    id manager = PJQGMisakaManager();
    if (!manager) return NO;

    SEL add = NULL;
    switch (kind) {
        case PJQGKindGroup: add = NSSelectorFromString(@"addGroupData:");      break;
        case PJQGKindChat:  add = NSSelectorFromString(@"addChatData:");       break;
        case PJQGKindOther: add = NSSelectorFromString(@"addOtherGroupData:"); break;
    }

    BOOL ok = NO;
    if (add && [manager respondsToSelector:add]) {
        ((void (*)(id, SEL, id))objc_msgSend)(manager, add, chatId);
        ok = YES;
    }
    // 兜底：有些版本用统一的 selectChat 动作
    if (!ok) {
        SEL sel = NSSelectorFromString(@"misaka_selectChatAction");
        if ([manager respondsToSelector:sel]) {
            ((void (*)(id, SEL))objc_msgSend)(manager, sel);
            ok = YES;
        }
    }
    // 刷新主界面分栏
    SEL rebuild = NSSelectorFromString(@"rebuildMainSessions");
    if ([manager respondsToSelector:rebuild]) {
        ((void (*)(id, SEL))objc_msgSend)(manager, rebuild);
    }
    return ok;
}

#pragma mark - 按钮行为控制器

@interface PJQGChatAction : NSObject
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, weak) UIButton *button;
+ (instancetype)actionFor:(UIViewController *)vc;
- (void)install;
- (void)refreshTitle;
@end

@implementation PJQGChatAction

+ (instancetype)actionFor:(UIViewController *)vc {
    PJQGChatAction *a = objc_getAssociatedObject(vc, kPJQGActionKey);
    if (!a) {
        a = [[PJQGChatAction alloc] init];
        a.host = vc;
        objc_setAssociatedObject(vc, kPJQGActionKey, a, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return a;
}

- (void)install {
    UIViewController *vc = self.host;
    if (!vc || !vc.navigationItem) return;

    // 幂等：已装过就只刷新标题
    for (UIBarButtonItem *it in vc.navigationItem.rightBarButtonItems ?: @[]) {
        if (it.customView && [it.customView isKindOfClass:UIButton.class]
            && [it.customView.accessibilityIdentifier isEqualToString:@"pjqg_button"]) {
            self.button = (UIButton *)it.customView;
            [self refreshTitle];
            return;
        }
    }

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.accessibilityIdentifier = @"pjqg_button";
    btn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [btn addTarget:self action:@selector(onTap:) forControlEvents:UIControlEventTouchUpInside];
    [btn sizeToFit];

    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    lp.minimumPressDuration = 0.45;
    [btn addGestureRecognizer:lp];

    self.button = btn;

    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithCustomView:btn];
    NSMutableArray *items = [NSMutableArray arrayWithArray:vc.navigationItem.rightBarButtonItems ?: @[]];
    [items insertObject:item atIndex:0];
    vc.navigationItem.rightBarButtonItems = items;

    [self refreshTitle];
}

- (void)refreshTitle {
    NSInteger k = PJQGDefaultKind();
    NSString *t = (k < 0) ? @"分组" : [NSString stringWithFormat:@"分组·%@", PJQGKindName((PJQGKind)k)];
    [self.button setTitle:t forState:UIControlStateNormal];
    [self.button sizeToFit];
}

#pragma mark 交互

- (void)onTap:(UIButton *)sender {
    NSInteger d = PJQGDefaultKind();

    // 尚未设置默认 → 选一次，并把它设为默认
    if (d < 0) {
        [self presentPickerSetDefault:YES];
        return;
    }

    // 已有默认 → 直接归入
    UIViewController *vc = self.host;
    NSString *chatId = PJQGChatId(vc);
    if (chatId.length == 0) { PJQGToast(vc.view, @"未能识别当前会话"); return; }

    BOOL ok = PJQGApply(chatId, (PJQGKind)d);
    PJQGToast(vc.view, ok
              ? [NSString stringWithFormat:@"已归入：%@（默认）", PJQGKindName((PJQGKind)d)]
              : @"失败：未检测到 MikotoHelper 分组模块");
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    [self presentMenu];
}

#pragma mark 菜单与选择器

- (void)presentMenu {
    UIViewController *vc = self.host;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"快速分组"
                                message:nil
                                preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"修改默认分组…"
                        style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *a) { [self presentPickerSetDefault:YES]; }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"本次归入其他分组…"
                        style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *a) { [self presentPickerSetDefault:NO]; }]];

    NSInteger d = PJQGDefaultKind();
    if (d >= 0) {
        [sheet addAction:[UIAlertAction actionWithTitle:
                            [NSString stringWithFormat:@"清除默认分组（当前：%@）", PJQGKindName((PJQGKind)d)]
                            style:UIAlertActionStyleDestructive
                            handler:^(UIAlertAction *a) {
            PJQGSetDefaultKind(-1);
            [self refreshTitle];
            PJQGToast(self.host.view, @"已清除默认分组");
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                        style:UIAlertActionStyleCancel handler:nil]];

    [self anchorPopover:sheet];
    [vc presentViewController:sheet animated:YES completion:nil];
}

- (void)presentPickerSetDefault:(BOOL)setDefault {
    UIViewController *vc = self.host;
    NSString *title = setDefault ? @"选择默认分组" : @"本次归入";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                message:setDefault ? @"选择后将成为默认分组，之后单击按钮即可直接归入" : nil
                                preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSInteger k = PJQGKindGroup; k <= PJQGKindOther; k++) {
        NSString *name = PJQGKindName((PJQGKind)k);
        [sheet addAction:[UIAlertAction actionWithTitle:name
                            style:UIAlertActionStyleDefault
                            handler:^(UIAlertAction *a) {
            if (setDefault) {
                PJQGSetDefaultKind(k);
                [self refreshTitle];
            }
            NSString *chatId = PJQGChatId(self.host);
            if (chatId.length == 0) { PJQGToast(self.host.view, @"未能识别当前会话"); return; }
            BOOL ok = PJQGApply(chatId, (PJQGKind)k);
            PJQGToast(self.host.view, ok
                      ? [NSString stringWithFormat:@"已归入：%@%@", name, setDefault ? @"（已设为默认）" : @""]
                      : @"失败：未检测到 MikotoHelper 分组模块");
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                        style:UIAlertActionStyleCancel handler:nil]];

    [self anchorPopover:sheet];
    [vc presentViewController:sheet animated:YES completion:nil];
}

// iPad / 大屏必需 popover 锚点
- (void)anchorPopover:(UIAlertController *)sheet {
    sheet.popoverPresentationController.sourceView = self.button ?: self.host.view;
    sheet.popoverPresentationController.sourceRect = self.button.bounds;
}

@end

#pragma mark - Hook：聊天窗口

%hook BaseMsgContentViewController

- (void)viewDidLoad {
    %orig;
    // 显式转型：BaseMsgContentViewController 在本编译单元内无声明，
    // clang 无法推出其继承链，需手动转成 UIViewController *
    [[PJQGChatAction actionFor:(UIViewController *)self] install];
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    // 每次出现都走一遍 install（幂等）：防止微信后续重设 rightBarButtonItems 把按钮冲掉
    // 显式转型：BaseMsgContentViewController 在本编译单元内无声明，
    // clang 无法推出其继承链，需手动转成 UIViewController *
    [[PJQGChatAction actionFor:(UIViewController *)self] install];
}

%end

#pragma mark - 载入日志

%ctor {
    NSLog(@"[MikotoQuickGroup] loaded. MikotoHelper(Misaka)=%@ default=%ld",
          PJQGMisakaManager() ? @"✓ 已检测到" : @"✗ 未检测到",
          (long)PJQGDefaultKind());
}
