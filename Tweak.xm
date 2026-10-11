// ============================================================================
//  MikotoQuickGroup v1.1  —— 微信聊天界面「快速分组」按钮（诊断增强版）
// ----------------------------------------------------------------------------
//  依赖宿主 : WeChat (com.tencent.xin) + MikotoHelper.dylib（提供 Misaka 分组能力）
//
//  v1.1 相比 v1.0 的改动（针对"完全没反应"）：
//   1. 【自证加载】%ctor 启动后弹窗 + 写日志文件，明确告诉你 dylib 有没有被加载
//   2. 【多类名匹配】不再只 hook BaseMsgContentViewController，改为 hook
//      UIViewController 并在运行时按多种特征识别聊天窗口（类名 + 是否响应 m_nsChatName）
//      —— 微信改类名也不会失效
//   3. 【悬浮兜底】导航栏按钮之外，额外提供可拖动的悬浮球（可在菜单里开关）
//      —— 即使微信用自绘导航栏，按钮也一定看得见
//   4. 【运行时探测】自动扫描 MikotoHelper 的全部 PJ* 类，找出真正实现了
//      addGroupData:/addChatData:/addOtherGroupData: 的对象（含对象图有界搜索）
//   5. 【参数自适应】读取方法的 type encoding，判断该传 NSString 还是会话对象
//   6. 【诊断报告】长按按钮 →「查看诊断报告」，可一键复制发给开发者
//
//  交互约定 :
//    · 单击按钮  → 直接归入「默认分组」；未设置默认则弹选择器并把选择存为默认
//    · 长按按钮  → 菜单：修改默认 / 本次归入其他 / 清除默认 / 诊断报告 / 悬浮球开关
//    · 按钮标题  → 导航栏显示「分组·群聊」，悬浮球显示「群聊」，未设置显示「分组」
// ============================================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>
#import <unistd.h>
#import <sys/utsname.h>

#pragma mark - 常量

static NSString *const kPJQGDefaultKindKey = @"pjqg_default_kind";   // NSInteger, -1 = 未设置
static NSString *const kPJQGBubbleVisibleKey = @"pjqg_bubble_visible";
static NSString *const kPJQGSilentKey = @"pjqg_silent_alert";
static const void    *kPJQGActionKey = &kPJQGActionKey;
static const void    *kPJQGBubbleKey = &kPJQGBubbleKey;

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

#pragma mark - 日志（文件 + 内存报告）

static NSMutableString *gPJQGReport = nil;   // 诊断报告（内存）
static NSString        *gPJQGLogPath = nil;  // 日志落盘路径

static NSString *PJQGLogPath(void) {
    if (gPJQGLogPath) return gPJQGLogPath;
    NSArray *dirs = @[ @"/var/mobile/Documents",
                       @"/var/mobile/Library/Preferences",
                       NSTemporaryDirectory() ];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *d in dirs) {
        if (d.length == 0) continue;
        if (![fm fileExistsAtPath:d]) {
            [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
        }
        if ([fm isWritableFileAtPath:d]) {
            gPJQGLogPath = [d stringByAppendingPathComponent:@"MikotoQuickGroup.log"];
            return gPJQGLogPath;
        }
    }
    gPJQGLogPath = @"/tmp/MikotoQuickGroup.log";
    return gPJQGLogPath;
}

static void PJQGLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!s) return;

    NSLog(@"[MikotoQuickGroup] %@", s);

    if (!gPJQGReport) gPJQGReport = [NSMutableString string];
    [gPJQGReport appendFormat:@"%@\n", s];
    // 内存报告只保留尾部（防止无限增长）
    if (gPJQGReport.length > 24000) {
        [gPJQGReport deleteCharactersInRange:NSMakeRange(0, 8000)];
        NSRange nl = [gPJQGReport rangeOfString:@"\n"];
        if (nl.location != NSNotFound) [gPJQGReport deleteCharactersInRange:NSMakeRange(0, NSMaxRange(nl))];
    }

    // 落盘（失败静默）
    NSString *p = PJQGLogPath();
    if (p.length == 0) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *attr = [fm attributesOfItemAtPath:p error:NULL];
    if (attr && [attr[NSFileSize] unsignedLongLongValue] > 256 * 1024) [fm removeItemAtPath:p error:NULL];

    NSString *line = [s stringByAppendingString:@"\n"];
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return;
    if (![fm fileExistsAtPath:p]) { [d writeToFile:p atomically:YES]; return; }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!fh) return;
    @try { [fh seekToEndOfFile]; [fh writeData:d]; }
    @catch (NSException *e) { /* 忽略 */ }
    @finally { [fh closeFile]; }
}

#pragma mark - 默认分组持久化

static NSInteger PJQGDefaultKind(void) {
    NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kPJQGDefaultKindKey];
    return n ? n.integerValue : -1;
}

static void PJQGSetDefaultKind(NSInteger k) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (k < 0) [d removeObjectForKey:kPJQGDefaultKindKey];
    else       [d setInteger:k forKey:kPJQGDefaultKindKey];
    [d synchronize];
}

static BOOL PJQGBubbleVisible(void) {
    NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kPJQGBubbleVisibleKey];
    return n ? n.boolValue : YES;   // 默认开启（诊断期内先保证"看得见"）
}

static void PJQGSetBubbleVisible(BOOL v) {
    [[NSUserDefaults standardUserDefaults] setBool:v forKey:kPJQGBubbleVisibleKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - 轻量 Toast

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
        l.text = text;
        l.textColor = UIColor.whiteColor;
        l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        l.textAlignment = NSTextAlignmentCenter;
        l.numberOfLines = 0;
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.84];
        l.layer.cornerRadius = 10;
        l.clipsToBounds = YES;

        CGSize max = CGSizeMake(w.bounds.size.width - 80, CGFLOAT_MAX);
        CGSize sz = [l sizeThatFits:max];
        l.frame = CGRectMake(0, 0, sz.width + 34, sz.height + 22);
        l.center = CGPointMake(w.bounds.size.width / 2, w.bounds.size.height * 0.76);
        [w addSubview:l];

        l.alpha = 0;
        [UIView animateWithDuration:0.18 animations:^{ l.alpha = 1.0; }
                         completion:^(BOOL f) {
            [UIView animateWithDuration:0.30 delay:1.30 options:0
                             animations:^{ l.alpha = 0.0; }
                             completion:^(BOOL f2) { [l removeFromSuperview]; }];
        }];
    });
}

#pragma mark - 运行时反射工具

// 收集「实例方法或类方法」中包含 sel 的类名（prefix 为 nil 表示不过滤）
static NSArray *PJQGClassesRespondingTo(SEL sel) {
    if (!sel) return @[];
    NSMutableArray *out = [NSMutableArray array];
    unsigned int count = 0;
    Class *all = objc_copyClassList(&count);
    if (!all) return out;
    for (unsigned int i = 0; i < count; i++) {
        Class c = all[i];
        if (!c) continue;
        const char *nm = class_getName(c);
        if (!nm) continue;
        BOOL hit = (class_getInstanceMethod(c, sel) != NULL) ||
                   (class_getClassMethod(c, sel) != NULL);
        if (hit) [out addObject:[NSString stringWithUTF8String:nm]];
    }
    free(all);
    return out;
}

static NSArray *PJQGAllClassNamesWithPrefix(NSString *prefix) {
    NSMutableArray *out = [NSMutableArray array];
    unsigned int count = 0;
    Class *all = objc_copyClassList(&count);
    if (!all) return out;
    for (unsigned int i = 0; i < count; i++) {
        const char *nm = class_getName(all[i]);
        if (!nm) continue;
        NSString *s = [NSString stringWithUTF8String:nm];
        if (prefix.length == 0 || [s hasPrefix:prefix]) [out addObject:s];
    }
    free(all);
    return out;
}

// 取实例对象的所有对象型 ivar
static void PJQGEnumerateIvars(Class cls, id obj, void (^blk)(NSString *name, id value)) {
    Class cur = cls;
    int guard = 0;
    while (cur && cur != [NSObject class] && guard++ < 12) {
        unsigned int n = 0;
        Ivar *ivars = class_copyIvarList(cur, &n);
        if (ivars) {
            for (unsigned int i = 0; i < n; i++) {
                const char *tn = ivar_getTypeEncoding(ivars[i]);
                if (!tn || tn[0] != '@') continue;
                const char *in = ivar_getName(ivars[i]);
                @try {
                    id v = object_getIvar(obj, ivars[i]);
                    if (v && in) blk([NSString stringWithUTF8String:in], v);
                } @catch (NSException *e) { /* 忽略 */ }
            }
            free(ivars);
        }
        cur = class_getSuperclass(cur);
    }
}

static BOOL PJQGIsLeafObject(id o) {
    return [o isKindOfClass:NSString.class] || [o isKindOfClass:NSNumber.class] ||
           [o isKindOfClass:NSData.class]   || [o isKindOfClass:NSArray.class]  ||
           [o isKindOfClass:NSDictionary.class] || [o isKindOfClass:NSSet.class];
}

// 有界对象图搜索：找到一个「响应 sel」的活对象
static id PJQGGraphFind(SEL sel, id root, int depth, int *budget, NSMutableSet *seen, NSMutableArray *paths, NSString *path) {
    if (!root || !sel || *budget <= 0) return nil;
    if (PJQGIsLeafObject(root)) return nil;

    NSValue *key = [NSValue valueWithNonretainedObject:root];
    if ([seen containsObject:key]) return nil;
    [seen addObject:key];
    (*budget)--;

    if ([root respondsToSelector:sel]) {
        if (paths && path) [paths addObject:[NSString stringWithFormat:@"%@ (%@)", path, NSStringFromClass([root class])]];
        return root;
    }
    if (depth <= 0) return nil;

    __block id found = nil;
    PJQGEnumerateIvars([root class], root, ^(NSString *name, id v) {
        if (found || *budget <= 0) return;
        found = PJQGGraphFind(sel, v, depth - 1, budget, seen, paths,
                              path ? [NSString stringWithFormat:@"%@.%@", path, name] : name);
    });
    return found;
}

// 收集若干"根对象"（主界面 VC 树 + 当前 VC）
static NSArray *PJQGRootObjects(id extra) {
    NSMutableArray *roots = [NSMutableArray array];
    if (extra) [roots addObject:extra];

    UIApplication *app = UIApplication.sharedApplication;
    UIWindow *kw = nil;
    for (UIWindow *w in app.windows) { if (w.isKeyWindow) { kw = w; break; } }
    if (!kw) kw = app.windows.firstObject;

    NSMutableArray *vcQueue = [NSMutableArray array];
    UIViewController *rootVC = kw.rootViewController;
    if (rootVC) [vcQueue addObject:rootVC];

    int guard = 0;
    while (vcQueue.count && guard++ < 40) {
        UIViewController *vc = vcQueue.firstObject;
        [vcQueue removeObjectAtIndex:0];
        [roots addObject:vc];
        if (vc.presentedViewController) [vcQueue addObject:vc.presentedViewController];
        for (UIViewController *c in vc.childViewControllers) [vcQueue addObject:c];
        if ([vc isKindOfClass:UINavigationController.class]) {
            for (UIViewController *c in ((UINavigationController *)vc).viewControllers) [vcQueue addObject:c];
        }
        if ([vc isKindOfClass:UITabBarController.class]) {
            UIViewController *sel = ((UITabBarController *)vc).selectedViewController;
            if (sel) [vcQueue addObject:sel];
        }
    }
    return roots;
}

#pragma mark - MikotoHelper 桥接层

// 会话 VC 的候选数据源：取会话 ID / 会话对象
static NSArray *PJQGChatIdKeyCandidates(void) {
    return @[ @"m_nsChatName", @"m_nsRealChatUsr", @"m_nsChatRoomUserName",
              @"chatUserName", @"m_nsUsrName", @"m_nsToUsr" ];
}

// 在 VC（以及它的 logicController 等 ivar）里找会话标识
static NSString *PJQGChatId(id vc) {
    if (!vc) return nil;
    for (NSString *k in PJQGChatIdKeyCandidates()) {
        @try {
            id v = [vc valueForKey:k];
            if ([v isKindOfClass:NSString.class] && [v length] > 0) {
                PJQGLog(@"  · 会话ID 命中: %@ = %@", k, v);
                return v;
            }
        } @catch (NSException *e) { /* 忽略 */ }
    }
    // 再往一层：logicController / logic / m_logicController 等
    NSArray *holders = @[ @"logicController", @"m_logicController", @"logic",
                          @"m_logic", @"controller", @"chatController" ];
    for (NSString *h in holders) {
        id child = nil;
        @try { child = [vc valueForKey:h]; } @catch (NSException *e) { continue; }
        if (!child) continue;
        for (NSString *k in PJQGChatIdKeyCandidates()) {
            @try {
                id v = [child valueForKey:k];
                if ([v isKindOfClass:NSString.class] && [v length] > 0) {
                    PJQGLog(@"  · 会话ID 命中: %@.%@ = %@", h, k, v);
                    return v;
                }
            } @catch (NSException *e) { /* 忽略 */ }
        }
    }
    return nil;
}

// 候选单例访问器
static NSArray *PJQGSingletonGetters(void) {
    return @[ @"sharedInstance", @"sharedManager", @"defaultManager", @"shared",
              @"manager", @"defaultInstance", @"instance", @"getInstance",
              @"sharedModel", @"sharedDataModel", @"currentManager" ];
}

// 找一个「响应 sel」的对象：先试 PJ* 单例，再做对象图有界搜索
static id PJQGFindProvider(SEL sel, id hint, NSString **howFound) {
    if (!sel) return nil;
    if (howFound) *howFound = nil;

    // ① 类方法/单例
    for (NSString *cn in PJQGClassesRespondingTo(sel)) {
        if (![cn hasPrefix:@"PJ"] && ![cn hasPrefix:@"Misaka"] && ![cn hasPrefix:@"MM"]) continue;
        Class c = NSClassFromString(cn);
        if (!c) continue;
        // 类方法直接可用
        if (class_getClassMethod(c, sel)) {
            if (howFound) *howFound = [NSString stringWithFormat:@"类方法 %@.%@", cn, NSStringFromSelector(sel)];
            return (id)c;
        }
        for (NSString *g in PJQGSingletonGetters()) {
            SEL gs = NSSelectorFromString(g);
            if (![c respondsToSelector:gs]) continue;
            @try {
                id inst = ((id (*)(id, SEL))objc_msgSend)(c, gs);
                if (inst && [inst respondsToSelector:sel]) {
                    if (howFound) *howFound = [NSString stringWithFormat:@"单例 %@.%@", cn, g];
                    return inst;
                }
            } @catch (NSException *e) { /* 忽略 */ }
        }
    }

    // ② 对象图有界搜索
    int budget = 1500;
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *paths = [NSMutableArray array];
    NSArray *roots = PJQGRootObjects(hint);
    for (id r in roots) {
        id found = PJQGGraphFind(sel, r, 4, &budget, seen, paths, NSStringFromClass([r class]));
        if (found) {
            if (howFound) *howFound = paths.lastObject ?: NSStringFromClass([found class]);
            return found;
        }
        if (budget <= 0) break;
    }
    return nil;
}

// 读方法第 1 个参数的类名（nil 表示无/未知）
static NSString *PJQGFirstArgClassName(id target, SEL sel) {
    if (!target || !sel) return nil;
    Class c = [target class];
    Method m = NULL;
    while (c && !m) { m = class_getInstanceMethod(c, sel); c = class_getSuperclass(c); }
    if (!m) return nil;
    const char *enc = method_getTypeEncoding(m);
    if (!enc) return nil;
    const char *p = strstr(enc, "@\"");
    if (!p) return nil;
    p += 2;
    const char *e = strchr(p, '"');
    if (!e || e <= p) return nil;
    return [[NSString alloc] initWithBytes:p length:(NSUInteger)(e - p) encoding:NSUTF8StringEncoding];
}

// 在对象图里找一个指定类的实例（浅层搜索）
static id PJQGFindInstanceOfClass(Class want, id hint) {
    if (!want) return nil;
    __block id hit = nil;
    NSArray *roots = PJQGRootObjects(hint);
    for (id r in roots) {
        if ([r isKindOfClass:want]) return r;
        PJQGEnumerateIvars([r class], r, ^(NSString *n, id v) {
            if (hit) return;
            if ([v isKindOfClass:want]) hit = v;
            else if (!PJQGIsLeafObject(v)) {
                PJQGEnumerateIvars([v class], v, ^(NSString *n2, id v2) {
                    if (!hit && [v2 isKindOfClass:want]) hit = v2;
                });
            }
        });
        if (hit) return hit;
    }
    return nil;
}

// 找出真正实现了 add*Data: 的对象并调用
static BOOL PJQGApply(NSString *chatId, PJQGKind kind) {
    if (chatId.length == 0) return NO;

    SEL add = NULL;
    switch (kind) {
        case PJQGKindGroup: add = NSSelectorFromString(@"addGroupData:");      break;
        case PJQGKindChat:  add = NSSelectorFromString(@"addChatData:");       break;
        case PJQGKindOther: add = NSSelectorFromString(@"addOtherGroupData:"); break;
    }
    if (!add) return NO;

    NSString *how = nil;
    id provider = PJQGFindProvider(add, nil, &how);
    PJQGLog(@"[apply] %@ → provider=%@  via=%@",
            NSStringFromSelector(add), provider ? NSStringFromClass([provider class]) : @"(未找到)", how ?: @"-");
    if (!provider) return NO;

    // 参数类型自适应：读 type encoding 判断该传 NSString 还是会话对象
    NSString *argCls = PJQGFirstArgClassName(provider, add);
    BOOL wantString = (argCls.length == 0) ||
                      [argCls isEqualToString:@"NSString"] ||
                      [argCls isEqualToString:@"NSMutableString"] ||
                      [argCls isEqualToString:@"NSObject"];
    id arg = chatId;
    PJQGLog(@"[apply] 参数类型 = %@ → 传 %@", argCls.length ? argCls : @"(未知)", wantString ? @"NSString" : @"对象");

    if (!wantString) {
        Class ac = NSClassFromString(argCls);
        id obj = PJQGFindInstanceOfClass(ac, nil);
        if (obj) { arg = obj; PJQGLog(@"[apply] 已取得参数对象: %@", NSStringFromClass([obj class])); }
        else PJQGLog(@"[apply] 未找到 %@ 实例，仍按 NSString 传入", argCls);
    }

    BOOL ok = NO;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(provider, add, arg);
        ok = YES;
    }
    @catch (NSException *e) {
        PJQGLog(@"[apply] 调用 %@ 抛异常: %@", NSStringFromSelector(add), e.reason);
    }

    // 兜底：统一的 selectChat 动作
    if (!ok) {
        SEL sel2 = NSSelectorFromString(@"misaka_selectChatAction");
        if ([provider respondsToSelector:sel2]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(provider, sel2); ok = YES; }
            @catch (NSException *e) { /* 忽略 */ }
        }
    }

    // 刷新主界面分栏
    SEL rebuild = NSSelectorFromString(@"rebuildMainSessions");
    NSString *how2 = nil;
    id rb = PJQGFindProvider(rebuild, nil, &how2);
    if (rb) {
        @try { ((void (*)(id, SEL))objc_msgSend)(rb, rebuild); PJQGLog(@"[apply] rebuildMainSessions via %@", how2 ?: @"-"); }
        @catch (NSException *e) { /* 忽略 */ }
    } else {
        PJQGLog(@"[apply] 未找到 rebuildMainSessions");
    }
    return ok;
}

#pragma mark - 诊断报告

static NSString *PJQGDeviceName(void) {
    struct utsname u;
    if (uname(&u) == 0) return [NSString stringWithFormat:@"%s (%s)", u.machine, u.version];
    return @"?";
}

static NSString *PJQGDiagnose(id chatVC) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"MikotoQuickGroup 诊断报告 v1.1\n"];
    [s appendFormat:@"时间     : %@\n", [NSDate date]];
    [s appendFormat:@"设备     : %@\n", PJQGDeviceName()];
    [s appendFormat:@"PID      : %d\n", getpid()];
    [s appendFormat:@"Bundle   : %@\n", NSBundle.mainBundle.bundleIdentifier ?: @"?"];
    [s appendFormat:@"WeChat   : %@ (%@)\n",
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?"];
    [s appendFormat:@"日志文件 : %@\n", PJQGLogPath()];

    [s appendString:@"\n--- MikotoHelper 是否已加载 ---\n"];
    NSArray *probe = @[ @"PJGroupDataModel", @"PJMisakaManager", @"PJGroupManager",
                        @"PJManagerModel", @"PJHelper", @"PJPluginModel" ];
    for (NSString *cn in probe) {
        [s appendFormat:@"  %-20s %@\n", cn.UTF8String, NSClassFromString(cn) ? @"✓ 存在" : @"✗ 不存在"];
    }

    [s appendString:@"\n--- 谁实现了分组方法 ---\n"];
    NSArray *sels = @[ @"addGroupData:", @"addChatData:", @"addOtherGroupData:",
                       @"misaka_selectChatAction", @"rebuildMainSessions",
                       @"chatIsChatAction:", @"groupIsChatAction:" ];
    for (NSString *sn in sels) {
        NSArray *cls = PJQGClassesRespondingTo(NSSelectorFromString(sn));
        [s appendFormat:@"  %-24s [%lu] %@\n", sn.UTF8String, (unsigned long)cls.count,
            cls.count ? [cls componentsJoinedByString:@", "] : @"(无)"];
    }

    [s appendString:@"\n--- PJ* 类总量 ---\n"];
    NSArray *pj = PJQGAllClassNamesWithPrefix(@"PJ");
    [s appendFormat:@"  PJ* 类 %lu 个\n", (unsigned long)pj.count];
    NSArray *pjg = PJQGAllClassNamesWithPrefix(@"PJGroup");
    if (pjg.count) [s appendFormat:@"  PJGroup*: %@\n", [pjg componentsJoinedByString:@", "]];
    NSArray *pjm = PJQGAllClassNamesWithPrefix(@"PJMisaka");
    if (pjm.count) [s appendFormat:@"  PJMisaka*: %@\n", [pjm componentsJoinedByString:@", "]];

    [s appendString:@"\n--- 当前聊天窗口 ---\n"];
    if (chatVC) {
        [s appendFormat:@"  类名: %@\n", NSStringFromClass([chatVC class])];
        NSString *cid = PJQGChatId(chatVC);
        [s appendFormat:@"  会话ID: %@\n", cid ?: @"(未取到)"];
    } else {
        [s appendString:@"  (尚未进入聊天窗口)\n"];
    }

    [s appendString:@"\n--- 对象图查找结果 ---\n"];
    NSString *how = nil;
    id p1 = PJQGFindProvider(NSSelectorFromString(@"addGroupData:"), chatVC, &how);
    [s appendFormat:@"  addGroupData:        %@  via %@\n", p1 ? NSStringFromClass([p1 class]) : @"(未找到)", how ?: @"-"];
    how = nil;
    id p2 = PJQGFindProvider(NSSelectorFromString(@"rebuildMainSessions"), chatVC, &how);
    [s appendFormat:@"  rebuildMainSessions: %@  via %@\n", p2 ? NSStringFromClass([p2 class]) : @"(未找到)", how ?: @"-"];

    [s appendString:@"\n--- NSUserDefaults 相关键 ---\n"];
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    int shown = 0;
    for (NSString *k in d.allKeys) {
        NSString *lk = k.lowercaseString;
        if ([lk containsString:@"pj"] || [lk containsString:@"mikoto"] ||
            [lk containsString:@"group"] || [lk containsString:@"misaka"] ||
            [lk hasPrefix:@"wx"] || [lk containsString:@"hongbao"]) {
            [s appendFormat:@"  %@ = %@\n", k, d[k]];
            if (++shown >= 40) { [s appendString:@"  ...(截断)\n"]; break; }
        }
    }
    if (shown == 0) [s appendString:@"  (无匹配键)\n"];

    return s;
}

#pragma mark - 按钮行为控制器

@interface PJQGChatAction : NSObject
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, weak) UIButton *navButton;
@property (nonatomic, weak) UIButton *bubble;
@property (nonatomic, assign) BOOL diagnosed;
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
    if (!vc || !vc.isViewLoaded) return;

    [self installNavButton:vc];
    [self installBubble:vc];
    [self refreshTitle];

    if (!self.diagnosed) {
        self.diagnosed = YES;
        PJQGLog(@"=== 命中聊天窗口: %@ ===", NSStringFromClass([vc class]));
        // 诊断放到稍后执行，避免和界面装配抢主线程
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSString *rep = PJQGDiagnose(self.host);
            PJQGLog(@"%@", rep);
        });
    }
}

- (void)installNavButton:(UIViewController *)vc {
    if (!vc.navigationItem) return;

    for (UIBarButtonItem *it in vc.navigationItem.rightBarButtonItems ?: @[]) {
        if (it.customView && [it.customView isKindOfClass:UIButton.class] &&
            [it.customView.accessibilityIdentifier isEqualToString:@"pjqg_button"]) {
            self.navButton = (UIButton *)it.customView;
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

    self.navButton = btn;
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithCustomView:btn];
    NSMutableArray *items = [NSMutableArray arrayWithArray:vc.navigationItem.rightBarButtonItems ?: @[]];
    [items insertObject:item atIndex:0];
    vc.navigationItem.rightBarButtonItems = items;
    PJQGLog(@"  · 导航栏按钮已插入 (%@)", NSStringFromClass([vc class]));
}

- (void)installBubble:(UIViewController *)vc {
    if (!PJQGBubbleVisible()) {
        [self.bubble removeFromSuperview];
        self.bubble = nil;
        return;
    }
    if (objc_getAssociatedObject(vc, kPJQGBubbleKey)) {
        self.bubble = objc_getAssociatedObject(vc, kPJQGBubbleKey);
        return;
    }
    UIView *hostView = vc.view;
    if (!hostView) return;

    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.accessibilityIdentifier = @"pjqg_bubble";
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.72];
    b.layer.cornerRadius = 20;
    b.clipsToBounds = YES;
    [b setTitle:@"分组" forState:UIControlStateNormal];
    CGSize sz = [b sizeThatFits:CGSizeMake(200, 40)];
    CGFloat w = MAX(52, sz.width + 22), h = 40;
    CGFloat top = 110;
    if (@available(iOS 11.0, *)) top = hostView.safeAreaInsets.top + 70;
    b.frame = CGRectMake(hostView.bounds.size.width - w - 8, top, w, h);
    b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    [b addTarget:self action:@selector(onTap:) forControlEvents:UIControlEventTouchUpInside];

    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    lp.minimumPressDuration = 0.45;
    [b addGestureRecognizer:lp];
    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [b addGestureRecognizer:pan];

    [hostView addSubview:b];
    [hostView bringSubviewToFront:b];
    self.bubble = b;
    objc_setAssociatedObject(vc, kPJQGBubbleKey, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PJQGLog(@"  · 悬浮球已创建 (%@)", NSStringFromClass([vc class]));
}

- (void)refreshTitle {
    NSInteger k = PJQGDefaultKind();
    NSString *longT = (k < 0) ? @"分组" : [NSString stringWithFormat:@"分组·%@", PJQGKindName((PJQGKind)k)];
    NSString *shortT = (k < 0) ? @"分组" : PJQGKindName((PJQGKind)k);

    [self.navButton setTitle:longT forState:UIControlStateNormal];
    [self.navButton sizeToFit];

    if (self.bubble) {
        [self.bubble setTitle:shortT forState:UIControlStateNormal];
    }
}

#pragma mark 交互

- (void)onTap:(UIButton *)sender {
    NSInteger d = PJQGDefaultKind();
    if (d < 0) { [self presentPickerSetDefault:YES]; return; }

    UIViewController *vc = self.host;
    NSString *chatId = PJQGChatId(vc);
    if (chatId.length == 0) { PJQGToast(vc.view, @"未能识别当前会话（见诊断报告）"); return; }

    BOOL ok = PJQGApply(chatId, (PJQGKind)d);
    PJQGToast(vc.view, ok
              ? [NSString stringWithFormat:@"已归入：%@（默认）", PJQGKindName((PJQGKind)d)]
              : @"失败：未找到分组接口，请长按按钮看诊断报告");
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    [self presentMenu];
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *b = g.view;
    UIView *p = b.superview;
    if (!b || !p) return;
    CGPoint t = [g translationInView:p];
    CGPoint c = CGPointMake(b.center.x + t.x, b.center.y + t.y);
    CGFloat halfW = b.bounds.size.width / 2, halfH = b.bounds.size.height / 2;
    c.x = MIN(MAX(c.x, halfW + 4), p.bounds.size.width - halfW - 4);
    c.y = MIN(MAX(c.y, halfH + 44), p.bounds.size.height - halfH - 44);
    b.center = c;
    [g setTranslation:CGPointZero inView:p];
}

#pragma mark 菜单与选择器

- (void)presentMenu {
    UIViewController *vc = self.host;
    if (!vc) return;
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

    [sheet addAction:[UIAlertAction actionWithTitle:@"查看诊断报告"
                        style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *a) { [self showDiagnose]; }]];

    [sheet addAction:[UIAlertAction actionWithTitle:
                        (PJQGBubbleVisible() ? @"隐藏悬浮球" : @"显示悬浮球")
                        style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *a) {
        PJQGSetBubbleVisible(!PJQGBubbleVisible());
        [self installBubble:self.host];
        [self refreshTitle];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                        style:UIAlertActionStyleCancel handler:nil]];

    [self anchorPopover:sheet];
    [vc presentViewController:sheet animated:YES completion:nil];
}

- (void)presentPickerSetDefault:(BOOL)setDefault {
    UIViewController *vc = self.host;
    if (!vc) return;
    NSString *title = setDefault ? @"选择默认分组" : @"本次归入";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                message:setDefault ? @"选择后成为默认分组，之后单击按钮即直接归入" : nil
                                preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSInteger k = PJQGKindGroup; k <= PJQGKindOther; k++) {
        NSString *name = PJQGKindName((PJQGKind)k);
        [sheet addAction:[UIAlertAction actionWithTitle:name
                            style:UIAlertActionStyleDefault
                            handler:^(UIAlertAction *a) {
            if (setDefault) { PJQGSetDefaultKind(k); [self refreshTitle]; }
            NSString *chatId = PJQGChatId(self.host);
            if (chatId.length == 0) { PJQGToast(self.host.view, @"未能识别当前会话（见诊断报告）"); return; }
            BOOL ok = PJQGApply(chatId, (PJQGKind)k);
            PJQGToast(self.host.view, ok
                      ? [NSString stringWithFormat:@"已归入：%@%@", name, setDefault ? @"（已设为默认）" : @""]
                      : @"失败：未找到分组接口，请长按按钮看诊断报告");
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                        style:UIAlertActionStyleCancel handler:nil]];
    [self anchorPopover:sheet];
    [vc presentViewController:sheet animated:YES completion:nil];
}

- (void)showDiagnose {
    NSString *rep = PJQGDiagnose(self.host);
    PJQGLog(@"%@", rep);

    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"诊断报告"
                             message:[rep substringToIndex:MIN((NSUInteger)1400, rep.length)]
                             preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"复制全文"
                        style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = rep;
        PJQGToast(self.host.view, @"已复制，可直接粘贴发送");
    }]];
    [al addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self.host presentViewController:al animated:YES completion:nil];
}

- (void)anchorPopover:(UIAlertController *)sheet {
    sheet.popoverPresentationController.sourceView = self.navButton ?: self.bubble ?: self.host.view;
    sheet.popoverPresentationController.sourceRect = (self.navButton ?: self.bubble).bounds;
}

@end

#pragma mark - 聊天窗口识别（版本无关）

static NSMutableDictionary *gPJQGClassMatch = nil;
static dispatch_once_t gPJQGOnce;

static BOOL PJQGIsChatVC(id vc) {
    if (!vc) return NO;
    NSString *n = NSStringFromClass([vc class]);
    if (n.length == 0) return NO;

    dispatch_once(&gPJQGOnce, ^{ gPJQGClassMatch = [NSMutableDictionary dictionary]; });
    NSNumber *cached = gPJQGClassMatch[n];
    if (cached) return cached.boolValue;

    BOOL ok = NO;
    if ([n containsString:@"MainFrame"] || [n containsString:@"NavigationController"] ||
        [n containsString:@"TabBar"] || [n containsString:@"Window"] ||
        [n containsString:@"Alert"] || [n containsString:@"PJQG"]) {
        ok = NO;
    } else if ([n containsString:@"MsgContent"] || [n containsString:@"ChatViewController"] ||
               [n containsString:@"ChatRoomViewController"] || [n containsString:@"SessionViewController"]) {
        ok = YES;
    } else if ([vc respondsToSelector:NSSelectorFromString(@"m_nsChatName")] ||
               [vc respondsToSelector:NSSelectorFromString(@"m_nsChatRoomUserName")]) {
        ok = YES;
    }

    gPJQGClassMatch[n] = @(ok);
    if (ok) PJQGLog(@"[匹配] 聊天窗口类 = %@", n);
    return ok;
}

#pragma mark - Hook

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (PJQGIsChatVC(self)) [[PJQGChatAction actionFor:(UIViewController *)self] install];
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (PJQGIsChatVC(self)) [[PJQGChatAction actionFor:(UIViewController *)self] install];
}

%end

#pragma mark - 载入自证

%ctor {
    // 注意：构造函数里只做"轻量"操作（不碰 NSUserDefaults），避免早期初始化死锁
    PJQGLog(@"================================================");
    PJQGLog(@"MikotoQuickGroup v1.1 已注入 (pid=%d)", getpid());
    PJQGLog(@"bundle = %@", NSBundle.mainBundle.bundleIdentifier ?: @"?");
    PJQGLog(@"MikotoHelper(Misaka) = %@",
            (NSClassFromString(@"PJGroupDataModel") || NSClassFromString(@"PJMisakaManager"))
                ? @"✓ 已检测到" : @"✗ 未检测到（MikotoHelper 可能未加载）");
    PJQGLog(@"日志文件 = %@", PJQGLogPath());
    PJQGLog(@"  · 若可在 Filza 中打开该文件，说明 dylib 确实被加载了");
    PJQGLog(@"================================================");

    // 4 秒后弹窗自证：能弹出来 = dylib 确实被加载了
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        BOOL misaka = (NSClassFromString(@"PJGroupDataModel") || NSClassFromString(@"PJMisakaManager"));
        PJQGLog(@"[自检] 默认分组 = %ld, 悬浮球 = %@, MikotoHelper = %@",
                (long)PJQGDefaultKind(), PJQGBubbleVisible() ? @"显示" : @"隐藏",
                misaka ? @"✓" : @"✗");

        if ([[NSUserDefaults standardUserDefaults] boolForKey:kPJQGSilentKey]) return;
        UIWindow *kw = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.isKeyWindow) { kw = w; break; }
        }
        UIViewController *host = kw.rootViewController;
        if (!host) return;
        UIAlertController *al = [UIAlertController
            alertControllerWithTitle:@"MikotoQuickGroup 已加载 ✓"
            message:[NSString stringWithFormat:
                @"插件已被微信加载，功能正在生效。\n\n"
                 "进入任意聊天窗口：右上角会出现「分组」按钮，另有一个可拖动的悬浮球（悬浮球一定能看到）。\n\n"
                 "MikotoHelper 分组模块：%@\n日志：%@",
                misaka ? @"✓ 已检测到" : @"✗ 未检测到",
                PJQGLogPath()]
            preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
        [al addAction:[UIAlertAction actionWithTitle:@"不再提示" style:UIAlertActionStyleDefault
                            handler:^(UIAlertAction *a) {
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kPJQGSilentKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }]];
        [host presentViewController:al animated:YES completion:nil];
    });
}
