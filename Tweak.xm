// ============================================================================
//  MikotoQuickGroup v1.2  —— 微信聊天界面「快速分组」按钮（崩溃加固版）
// ----------------------------------------------------------------------------
//  依赖宿主 : WeChat (com.tencent.xin) + MikotoHelper.dylib（提供 Misaka 分组能力）
//
//  v1.2 针对「点了就闪退」的改动：
//   1. 【崩溃取证】注册 NSUncaughtExceptionHandler + signal 处理器，
//      闪退前沿面包屑与调用栈写进日志文件，事后可查（无需连线 Xcode）
//   2. 【危险调用哨兵】每次调用 MikotoHelper 前后各写一次 NSUserDefaults 标记；
//      下次启动若发现标记仍在 = 上次就是死在这一步 → 自动进入安全模式并弹窗告知
//   3. 【先验签后调用】调用前解析方法签名（参数个数 + 每个参数的类型编码），
//      只有在我们能提供正确类型参数时才调用；类型对不上就"不调用只记录"
//      —— 彻底消灭"用错参数把人调崩"
//   4. 【接口探测】新增只读探测：打印候选选择子在候选类上的完整签名
//   5. 【首点加固】弹窗改从"最顶层 VC"present；popover 锚点仅在存在时设置；
//      全流程 @try/@catch
//   6. 【缓存】类扫描 / provider 查找结果缓存，避免重复重活儿卡主线程
//
//  交互约定 :
//    · 单击按钮  → 直接归入「默认分组」；未设置默认则弹选择器并把选择存为默认
//    · 长按按钮  → 菜单：修改默认 / 本次归入其他 / 清除默认 / 接口探测 / 安全模式 / 悬浮球
//    · 按钮标题  → 导航栏「分组·群聊」，悬浮球「群聊」，未设置显示「分组」
// ============================================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>
#import <fcntl.h>
#import <signal.h>
#import <execinfo.h>
#import <sys/utsname.h>

#pragma mark - 常量

static NSString *const kPJQGDefaultKindKey = @"pjqg_default_kind";   // NSInteger, -1 = 未设置
static NSString *const kPJQGBubbleVisibleKey = @"pjqg_bubble_visible";
static NSString *const kPJQGSilentKey = @"pjqg_silent_alert";
static NSString *const kPJQGRiskyFlagKey = @"pjqg_risky_open";       // 危险调用哨兵
static NSString *const kPJQGSafeModeKey = @"pjqg_safe_mode";
static const void    *kPJQGActionKey = &kPJQGActionKey;
static const void    *kPJQGBubbleKey = &kPJQGBubbleKey;
static const char    *kPJQGLogFile = "/var/mobile/Documents/MikotoQuickGroup.log";

// 前向声明
static BOOL PJQGIsClassObjectSafely(id o);
static NSString *PJQGLogPath(void);
static void PJQGLog(NSString *fmt, ...);

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

static NSString *PJQGSelectorForKind(PJQGKind k) {
    switch (k) {
        case PJQGKindGroup: return @"addGroupData:";
        case PJQGKindChat:  return @"addChatData:";
        case PJQGKindOther: return @"addOtherGroupData:";
    }
    return nil;
}

#pragma mark - 日志（文件 + 内存报告）

static NSMutableString *gPJQGReport = nil;
static NSString        *gPJQGLogPath = nil;

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

static void PJQGLogWrite(NSString *line) {
    if (line.length == 0) return;
    NSLog(@"[MikotoQuickGroup] %@", line);

    if (!gPJQGReport) gPJQGReport = [NSMutableString string];
    [gPJQGReport appendFormat:@"%@\n", line];
    if (gPJQGReport.length > 24000) {
        [gPJQGReport deleteCharactersInRange:NSMakeRange(0, 8000)];
        NSRange nl = [gPJQGReport rangeOfString:@"\n"];
        if (nl.location != NSNotFound) [gPJQGReport deleteCharactersInRange:NSMakeRange(0, NSMaxRange(nl))];
    }

    NSString *p = PJQGLogPath();
    if (p.length == 0) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *attr = [fm attributesOfItemAtPath:p error:NULL];
    if (attr && [attr[NSFileSize] unsignedLongLongValue] > 320 * 1024) [fm removeItemAtPath:p error:NULL];

    NSString *full = [line stringByAppendingString:@"\n"];
    NSData *d = [full dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return;
    if (![fm fileExistsAtPath:p]) { [d writeToFile:p atomically:YES]; return; }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!fh) return;
    @try { [fh seekToEndOfFile]; [fh writeData:d]; }
    @catch (NSException *e) { }
    @finally { [fh closeFile]; }
}

static void PJQGLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!s) return;
    @try { PJQGLogWrite(s); } @catch (NSException *e) { }
}

#pragma mark - 崩溃取证（崩溃现场也要能落盘，故用最底层调用）

static void PJQGRawWrite(const char *s) {
    if (!s) return;
    int fd = open(kPJQGLogFile, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) fd = open("/tmp/MikotoQuickGroup.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    ssize_t w = write(fd, s, strlen(s));
    (void)w;
    close(fd);
}

static NSUncaughtExceptionHandler *gPJQGPrevExceptionHandler = NULL;

static void PJQGExceptionHandler(NSException *e) {
    @try {
        NSMutableString *s = [NSMutableString string];
        [s appendString:@"\n!!! 未捕获异常 (ObjC) !!!\n"];
        [s appendFormat:@"name    : %@\n", e.name];
        [s appendFormat:@"reason  : %@\n", e.reason];
        [s appendFormat:@"userInfo: %@\n", e.userInfo];
        [s appendString:@"callStackSymbols:\n"];
        for (NSString *f in e.callStackSymbols) [s appendFormat:@"  %@\n", f];
        PJQGRawWrite(s.UTF8String);
    } @catch (NSException *x) { }
    if (gPJQGPrevExceptionHandler) gPJQGPrevExceptionHandler(e);
}

static void PJQGSignalHandler(int sig) {
    const char *names[] = { "", "SIGHUP", "SIGINT", "SIGQUIT", "SIGILL", "SIGTRAP",
                            "SIGABRT", "SIGEMT", "SIGFPE", "SIGKILL", "SIGBUS",
                            "SIGSEGV", "SIGSYS", "SIGPIPE", "SIGALRM", "SIGTERM" };
    const char *nm = (sig >= 1 && sig <= 15) ? names[sig] : "SIG?";

    char head[256];
    snprintf(head, sizeof(head), "\n!!! 致命信号 %d (%s) !!!\nbacktrace:\n", sig, nm);
    PJQGRawWrite(head);

    void *frames[64];
    int n = backtrace(frames, 64);
    if (n > 0) {
        int fd = open(kPJQGLogFile, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) fd = open("/tmp/MikotoQuickGroup.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) { backtrace_symbols_fd(frames, n, fd); close(fd); }
    }
    PJQGRawWrite("\n--- end ---\n");

    // 交还系统，保证 iOS 仍会生成 .ips 崩溃报告
    signal(sig, SIG_DFL);
    raise(sig);
}

static void PJQGInstallCrashHandlers(void) {
    gPJQGPrevExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&PJQGExceptionHandler);
    int sigs[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE };
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = PJQGSignalHandler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_NODEFER;
        sigaction(sigs[i], &sa, NULL);
    }
}

#pragma mark - 危险调用哨兵

// 调用 MikotoHelper 前落标记，正常返回后清掉。
// 下次启动若标记还在 = 上次运行死在这个调用里 → 自动进安全模式
static void PJQGRiskyBegin(const char *op) {
    PJQGLog(@"[risky] BEGIN %s", op);
    @try {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        [d setObject:[NSString stringWithUTF8String:op] forKey:kPJQGRiskyFlagKey];
        [d synchronize];
    } @catch (NSException *e) { }
}

static void PJQGRiskyEnd(void) {
    @try {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        [d removeObjectForKey:kPJQGRiskyFlagKey];
        [d synchronize];
    } @catch (NSException *e) { }
    PJQGLog(@"[risky] END");
}

#pragma mark - 持久化

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
    return n ? n.boolValue : YES;
}

static void PJQGSetBubbleVisible(BOOL v) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:v forKey:kPJQGBubbleVisibleKey];
    [d synchronize];
}

static BOOL PJQGSafeMode(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kPJQGSafeModeKey];
}

static void PJQGSetSafeMode(BOOL v) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:v forKey:kPJQGSafeModeKey];
    [d synchronize];
}

#pragma mark - 轻量 Toast

static void PJQGToast(UIView *host, NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
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
                [UIView animateWithDuration:0.30 delay:1.40 options:0
                                 animations:^{ l.alpha = 0.0; }
                                 completion:^(BOOL f2) { [l removeFromSuperview]; }];
            }];
        } @catch (NSException *e) { }
    });
}

#pragma mark - 运行时反射

static BOOL PJQGIsClassObjectSafely(id o) {
    if (!o) return NO;
    @try { return class_isMetaClass(object_getClass(o)); } @catch (NSException *e) { return NO; }
}

static NSMutableDictionary *gPJQGSelClassCache = nil;   // selector 名 -> 类名数组

static NSArray *PJQGClassesImplementing(SEL sel) {
    if (!sel) return @[];
    if (!gPJQGSelClassCache) gPJQGSelClassCache = [NSMutableDictionary dictionary];
    NSString *key = NSStringFromSelector(sel);
    NSArray *cached = gPJQGSelClassCache[key];
    if (cached) return cached;

    NSMutableArray *out = [NSMutableArray array];
    unsigned int count = 0;
    Class *all = objc_copyClassList(&count);
    if (all) {
        for (unsigned int i = 0; i < count; i++) {
            Class c = all[i];
            if (!c) continue;
            const char *nm = class_getName(c);
            if (!nm) continue;
            if (class_getInstanceMethod(c, sel) != NULL || class_getClassMethod(c, sel) != NULL) {
                [out addObject:[NSString stringWithUTF8String:nm]];
            }
        }
        free(all);
    }
    gPJQGSelClassCache[key] = out;
    return out;
}

static NSArray *PJQGClassNamesWithPrefix(NSString *prefix) {
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

// 取方法（同时兼容类方法与实例方法）
static Method PJQGGetMethod(id target, SEL sel, BOOL *isClassMethod) {
    BOOL isClassObj = PJQGIsClassObjectSafely(target);
    Class cls = isClassObj ? (Class)target : [target class];
    if (!cls) return NULL;
    Method m = NULL;
    BOOL cm = NO;
    if (isClassObj) {
        m = class_getClassMethod(cls, sel); cm = YES;
        if (!m) { m = class_getInstanceMethod(cls, sel); cm = NO; }
    } else {
        m = class_getInstanceMethod(cls, sel); cm = NO;
        if (!m) { m = class_getClassMethod(cls, sel); cm = YES; }
    }
    if (isClassMethod) *isClassMethod = cm;
    return m;
}

// 方法签名描述（诊断输出用）
static NSString *PJQGMethodInfo(id target, SEL sel) {
    if (!target || !sel) return @"(nil)";
    BOOL cm = NO;
    Method m = PJQGGetMethod(target, sel, &cm);
    if (!m) return [NSString stringWithFormat:@"(%@ %@) 方法不存在",
                    PJQGIsClassObjectSafely(target) ? @"+" : @"-", NSStringFromSelector(sel)];

    unsigned n = method_getNumberOfArguments(m);
    char rbuf[80] = {0};
    method_getReturnType(m, rbuf, sizeof(rbuf));
    NSMutableString *args = [NSMutableString string];
    for (unsigned i = 0; i < n; i++) {
        char b[80] = {0};
        method_getArgumentType(m, i, b, sizeof(b));
        if (i) [args appendString:@", "];
        [args appendFormat:@"%s", b];
    }
    return [NSString stringWithFormat:@"%s[%@ %@] 返回=%s 参数(%u): %@",
            cm ? "+" : "-", NSStringFromClass([target class]),
            NSStringFromSelector(sel), rbuf, n, args];
}

static NSString *PJQGArgumentType(id target, SEL sel, unsigned idx) {
    Method m = PJQGGetMethod(target, sel, NULL);
    if (!m) return nil;
    if (idx >= method_getNumberOfArguments(m)) return nil;
    char b[80] = {0};
    method_getArgumentType(m, idx, b, sizeof(b));
    return [NSString stringWithUTF8String:b];
}

#pragma mark - 验签（核心安全闸门）

// 0 个入参的方法：必须恰好是 self/_cmd 两个参数
static BOOL PJQGSignatureAllows0(id target, SEL sel, NSString **why) {
    Method m = PJQGGetMethod(target, sel, NULL);
    if (!m) { if (why) *why = @"方法不存在"; return NO; }
    unsigned n = method_getNumberOfArguments(m);
    if (n != 2) {
        if (why) *why = [NSString stringWithFormat:@"参数个数=%u（期望 2）", n];
        return NO;
    }
    if (why) *why = @"参数个数=2 → 可调用";
    return YES;
}

// 1 个入参的方法：只有能提供正确类型参数时才允许调用
static BOOL PJQGSignatureAllows(id target, SEL sel, NSString *stringArg, id *outArg, NSString **why) {
    if (!target || !sel) { if (why) *why = @"target/sel 为空"; return NO; }
    Method m = PJQGGetMethod(target, sel, NULL);
    if (!m) { if (why) *why = @"方法不存在"; return NO; }

    unsigned n = method_getNumberOfArguments(m);
    if (n != 3) {
        if (why) *why = [NSString stringWithFormat:@"参数个数=%u（期望 3：self/_cmd/1入参）", n];
        return NO;
    }

    NSString *type = PJQGArgumentType(target, sel, 2);
    if (type.length == 0) { if (why) *why = @"读不到参数类型"; return NO; }

    if ([type isEqualToString:@"@"] ||
        [type isEqualToString:@"@\"NSString\""] ||
        [type isEqualToString:@"@\"NSMutableString\""] ||
        [type isEqualToString:@"@\"NSObject\""]) {
        if (outArg) *outArg = stringArg;
        if (why) *why = [NSString stringWithFormat:@"参数类型 %@ → 传 NSString", type];
        return YES;
    }
    if ([type hasPrefix:@"@\""]) {
        if (why) *why = [NSString stringWithFormat:@"参数类型 %@ → 需要该类型的对象实例，v1.2 不硬凑，已阻止", type];
        return NO;
    }
    if (why) *why = [NSString stringWithFormat:@"参数类型 %@ → 非对象类型，已阻止", type];
    return NO;
}

#pragma mark - 会话 ID 读取（只读 KVC，全部兜异常）

static NSArray *PJQGChatIdKeyCandidates(void) {
    return @[ @"m_nsChatName", @"m_nsRealChatUsr", @"m_nsChatRoomUserName",
              @"chatUserName", @"m_nsUsrName", @"m_nsToUsr" ];
}

static NSString *PJQGSafeStringForKey(id obj, NSString *key, NSString **hitKey) {
    if (!obj || key.length == 0) return nil;
    @try {
        id v = [obj valueForKey:key];
        if ([v isKindOfClass:NSString.class] && [v length] > 0) {
            if (hitKey) *hitKey = key;
            return v;
        }
    } @catch (NSException *e) { }
    return nil;
}

static NSString *PJQGChatId(id vc, NSString **how) {
    if (!vc) return nil;
    for (NSString *k in PJQGChatIdKeyCandidates()) {
        NSString *hit = nil;
        NSString *v = PJQGSafeStringForKey(vc, k, &hit);
        if (v) { if (how) *how = hit; return v; }
    }
    for (NSString *h in @[ @"logicController", @"m_logicController", @"logic",
                           @"m_logic", @"controller", @"chatController" ]) {
        id child = nil;
        @try { child = [vc valueForKey:h]; } @catch (NSException *e) { continue; }
        if (!child || PJQGIsClassObjectSafely(child)) continue;
        for (NSString *k in PJQGChatIdKeyCandidates()) {
            NSString *hit = nil;
            NSString *v = PJQGSafeStringForKey(child, k, &hit);
            if (v) { if (how) *how = [NSString stringWithFormat:@"%@.%@", h, hit]; return v; }
        }
    }
    return nil;
}

#pragma mark - provider 查找（只走"类 / 单例"路径，不做对象图遍历）

static NSMutableDictionary *gPJQGProviderCache = nil;

static id PJQGFindProvider(SEL sel, NSString **howFound) {
    if (howFound) *howFound = nil;
    if (!sel) return nil;
    if (!gPJQGProviderCache) gPJQGProviderCache = [NSMutableDictionary dictionary];

    NSString *key = NSStringFromSelector(sel);
    id cached = gPJQGProviderCache[key];
    if (cached) {
        if (cached == [NSNull null]) return nil;
        if (howFound) *howFound = @"(缓存)";
        return cached;
    }

    for (NSString *cn in PJQGClassesImplementing(sel)) {
        if (![cn hasPrefix:@"PJ"] && ![cn hasPrefix:@"Misaka"]) continue;
        Class c = NSClassFromString(cn);
        if (!c) continue;

        if (class_getClassMethod(c, sel)) {
            if (howFound) *howFound = [NSString stringWithFormat:@"类方法 +[%@ %@]", cn, key];
            gPJQGProviderCache[key] = (id)c;
            return (id)c;
        }
        for (NSString *g in @[ @"sharedInstance", @"sharedManager", @"defaultManager", @"shared",
                               @"manager", @"defaultInstance", @"instance", @"getInstance",
                               @"sharedModel", @"sharedDataModel", @"currentManager" ]) {
            SEL gs = NSSelectorFromString(g);
            if (![c respondsToSelector:gs]) continue;
            @try {
                id inst = ((id (*)(id, SEL))objc_msgSend)(c, gs);
                if (inst && !PJQGIsClassObjectSafely(inst) && [inst respondsToSelector:sel]) {
                    if (howFound) *howFound = [NSString stringWithFormat:@"单例 +[%@ %@]", cn, g];
                    gPJQGProviderCache[key] = inst;
                    return inst;
                }
            } @catch (NSException *e) { }
        }
    }
    gPJQGProviderCache[key] = [NSNull null];
    return nil;
}

#pragma mark - 实际写入（验签 + 哨兵 + 兜异常）

typedef NS_ENUM(NSInteger, PJQGApplyResult) {
    PJQGApplyOK = 0,
    PJQGApplyNoProvider,
    PJQGApplyBadSignature,
    PJQGApplyException,
    PJQGApplySafeMode,
};

static NSString *PJQGApplyResultText(PJQGApplyResult r, NSString *detail) {
    switch (r) {
        case PJQGApplyOK:           return @"已归入";
        case PJQGApplyNoProvider:   return @"失败：未找到分组接口（长按→接口探测）";
        case PJQGApplyBadSignature: return [NSString stringWithFormat:@"已阻止调用（%@）", detail ?: @"签名不匹配"];
        case PJQGApplyException:    return [NSString stringWithFormat:@"调用报错：%@", detail ?: @"未知"];
        case PJQGApplySafeMode:     return @"安全模式中：已禁用写入";
    }
    return @"失败";
}

static PJQGApplyResult PJQGApply(NSString *chatId, PJQGKind kind, NSString **detail) {
    if (detail) *detail = nil;
    if (chatId.length == 0) { if (detail) *detail = @"会话 ID 为空"; return PJQGApplyNoProvider; }
    if (PJQGSafeMode()) return PJQGApplySafeMode;

    NSString *selName = PJQGSelectorForKind(kind);
    SEL add = NSSelectorFromString(selName);
    PJQGLog(@"[apply] 目标选择子 = %@", selName);

    NSString *how = nil;
    id provider = PJQGFindProvider(add, &how);
    PJQGLog(@"[apply] provider = %@  via %@",
            provider ? NSStringFromClass([provider class]) : @"(未找到)", how ?: @"-");
    if (!provider) { if (detail) *detail = @"无 provider"; return PJQGApplyNoProvider; }

    PJQGLog(@"[apply] 签名: %@", PJQGMethodInfo(provider, add));

    id arg = nil;
    NSString *why = nil;
    if (!PJQGSignatureAllows(provider, add, chatId, &arg, &why)) {
        PJQGLog(@"[apply] 验签未通过 → 不调用。原因: %@", why ?: @"?");
        if (detail) *detail = why;
        return PJQGApplyBadSignature;
    }
    PJQGLog(@"[apply] 验签通过: %@", why ?: @"ok");

    BOOL ok = NO;
    PJQGRiskyBegin("addData");
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(provider, add, arg);
        ok = YES;
    } @catch (NSException *e) {
        PJQGLog(@"[apply] 抛异常: %@", e.reason);
        if (detail) *detail = e.reason;
    }
    PJQGRiskyEnd();

    if (!ok) return PJQGApplyException;

    // 刷新主界面分栏：只有 0 入参签名才调
    SEL rebuild = NSSelectorFromString(@"rebuildMainSessions");
    NSString *how2 = nil;
    id rb = PJQGFindProvider(rebuild, &how2);
    if (rb) {
        NSString *why2 = nil;
        if (PJQGSignatureAllows0(rb, rebuild, &why2)) {
            PJQGLog(@"[apply] 刷新签名 OK: %@", why2 ?: @"");
            PJQGRiskyBegin("rebuildMainSessions");
            @try { ((void (*)(id, SEL))objc_msgSend)(rb, rebuild); PJQGLog(@"[apply] 已刷新 via %@", how2 ?: @"-"); }
            @catch (NSException *e) { PJQGLog(@"[apply] 刷新异常: %@", e.reason); }
            PJQGRiskyEnd();
        } else {
            PJQGLog(@"[apply] 刷新方法签名不允许调用: %@", why2 ?: @"?");
        }
    } else {
        PJQGLog(@"[apply] 未找到 rebuildMainSessions");
    }
    return PJQGApplyOK;
}

#pragma mark - 诊断报告

static NSString *PJQGDeviceName(void) {
    struct utsname u;
    if (uname(&u) == 0) return [NSString stringWithFormat:@"%s (%s)", u.machine, u.version];
    return @"?";
}

static NSString *PJQGDiagnose(id chatVC) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"MikotoQuickGroup 诊断报告 v1.2\n"];
    [s appendFormat:@"时间     : %@\n", [NSDate date]];
    [s appendFormat:@"设备     : %@\n", PJQGDeviceName()];
    [s appendFormat:@"PID      : %d\n", getpid()];
    [s appendFormat:@"Bundle   : %@\n", NSBundle.mainBundle.bundleIdentifier ?: @"?"];
    [s appendFormat:@"WeChat   : %@ (%@)\n",
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?"];
    [s appendFormat:@"日志文件 : %@\n", PJQGLogPath()];
    [s appendFormat:@"安全模式 : %@\n", PJQGSafeMode() ? @"开启" : @"关闭"];
    [s appendFormat:@"上次崩溃点: %@\n", [ud objectForKey:kPJQGRiskyFlagKey] ?: @"(无)"];

    [s appendString:@"\n--- MikotoHelper 是否已加载 ---\n"];
    for (NSString *cn in @[ @"PJGroupDataModel", @"PJMisakaManager", @"PJGroupManager",
                            @"PJManagerModel", @"PJHelper", @"PJPluginModel" ]) {
        [s appendFormat:@"  %-20s %@\n", cn.UTF8String, NSClassFromString(cn) ? @"✓ 存在" : @"✗ 不存在"];
    }

    [s appendString:@"\n--- 谁实现了这些方法 ---\n"];
    for (NSString *sn in @[ @"addGroupData:", @"addChatData:", @"addOtherGroupData:",
                            @"misaka_selectChatAction", @"rebuildMainSessions",
                            @"chatIsChatAction:", @"groupIsChatAction:" ]) {
        NSArray *cls = PJQGClassesImplementing(NSSelectorFromString(sn));
        [s appendFormat:@"  %-24s [%lu] %@\n", sn.UTF8String, (unsigned long)cls.count,
            cls.count ? [cls componentsJoinedByString:@", "] : @"(无)"];
    }

    [s appendString:@"\n--- 方法签名（决定能不能调用） ---\n"];
    for (NSString *sn in @[ @"addGroupData:", @"addChatData:", @"addOtherGroupData:",
                            @"misaka_selectChatAction", @"rebuildMainSessions" ]) {
        SEL sel = NSSelectorFromString(sn);
        NSArray *cls = PJQGClassesImplementing(sel);
        [s appendFormat:@"  · %@ (%lu 个类)\n", sn, (unsigned long)cls.count];
        if (cls.count == 0) { [s appendString:@"      (无类实现)\n"]; continue; }
        int shown = 0;
        for (NSString *cn in cls) {
            if (cls.count > 6 && ![cn hasPrefix:@"PJ"] && ![cn hasPrefix:@"Misaka"]) continue;
            Class c = NSClassFromString(cn);
            [s appendFormat:@"      %@\n", PJQGMethodInfo((id)c, sel)];
            [s appendFormat:@"      %@\n", PJQGMethodInfo(c, sel)];
            if (++shown >= 8) { [s appendString:@"      ...(截断)\n"]; break; }
        }
    }

    [s appendString:@"\n--- provider 解析 ---\n"];
    for (NSString *sn in @[ @"addGroupData:", @"addChatData:", @"addOtherGroupData:", @"rebuildMainSessions" ]) {
        NSString *how = nil;
        id p = PJQGFindProvider(NSSelectorFromString(sn), &how);
        [s appendFormat:@"  %-24s %@  via %@\n", sn.UTF8String,
            p ? NSStringFromClass([p class]) : @"(未找到)", how ?: @"-"];
    }

    [s appendString:@"\n--- PJ* 类清单 ---\n"];
    NSArray *pj = PJQGClassNamesWithPrefix(@"PJ");
    [s appendFormat:@"  PJ* 共 %lu 个\n", (unsigned long)pj.count];
    for (NSString *prefix in @[ @"PJGroup", @"PJMisaka", @"PJTag", @"PJHelper", @"PJUtils" ]) {
        NSMutableArray *hit = [NSMutableArray array];
        for (NSString *n in pj) if ([n hasPrefix:prefix]) [hit addObject:n];
        if (hit.count) [s appendFormat:@"  %@: %@\n", prefix, [hit componentsJoinedByString:@", "]];
    }

    [s appendString:@"\n--- 当前聊天窗口 ---\n"];
    if (chatVC) {
        [s appendFormat:@"  类名: %@\n", NSStringFromClass([chatVC class])];
        NSString *how = nil;
        NSString *cid = PJQGChatId(chatVC, &how);
        [s appendFormat:@"  会话ID: %@  (字段 %@)\n", cid ?: @"(未取到)", how ?: @"-"];
    } else {
        [s appendString:@"  (尚未进入聊天窗口)\n"];
    }

    [s appendString:@"\n--- NSUserDefaults 相关键 ---\n"];
    int shown = 0;
    NSDictionary *d = ud.dictionaryRepresentation;
    for (NSString *k in d.allKeys) {
        NSString *lk = k.lowercaseString;
        if ([lk containsString:@"pj"] || [lk containsString:@"mikoto"] ||
            [lk containsString:@"group"] || [lk containsString:@"misaka"] ||
            [lk hasPrefix:@"wx"]) {
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
    @try {
        UIViewController *vc = self.host;
        if (!vc || !vc.isViewLoaded) return;

        [self installNavButton:vc];
        [self installBubble:vc];
        [self refreshTitle];

        if (!self.diagnosed) {
            self.diagnosed = YES;
            PJQGLog(@"=== 命中聊天窗口: %@ ===", NSStringFromClass([vc class]));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try { PJQGLog(@"%@", PJQGDiagnose(self.host)); }
                @catch (NSException *e) { PJQGLog(@"[诊断] 生成报告失败: %@", e.reason); }
            });
        }
    } @catch (NSException *e) {
        PJQGLog(@"[install] 异常: %@", e.reason);
    }
}

- (void)installNavButton:(UIViewController *)vc {
    if (!vc.navigationItem) return;
    UINavigationItem *ni = vc.navigationItem;

    for (UIBarButtonItem *it in ni.rightBarButtonItems ?: @[]) {
        if (it.customView && [it.customView isKindOfClass:UIButton.class] &&
            [it.customView.accessibilityIdentifier isEqualToString:@"pjqg_button"]) {
            self.navButton = (UIButton *)it.customView;
            return;
        }
    }

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.accessibilityIdentifier = @"pjqg_button";
    btn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [btn setTitle:@"分组" forState:UIControlStateNormal];
    [btn addTarget:self action:@selector(onTap:) forControlEvents:UIControlEventTouchUpInside];
    [btn sizeToFit];

    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    lp.minimumPressDuration = 0.45;
    [btn addGestureRecognizer:lp];

    self.navButton = btn;
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithCustomView:btn];
    NSMutableArray *items = [NSMutableArray arrayWithArray:ni.rightBarButtonItems ?: @[]];
    [items insertObject:item atIndex:0];
    ni.rightBarButtonItems = items;
    PJQGLog(@"  · 导航栏按钮已插入");
}

- (void)installBubble:(UIViewController *)vc {
    if (!PJQGBubbleVisible()) {
        UIButton *old = objc_getAssociatedObject(vc, kPJQGBubbleKey);
        [old removeFromSuperview];
        objc_setAssociatedObject(vc, kPJQGBubbleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        self.bubble = nil;
        return;
    }
    UIView *hostView = vc.view;
    if (!hostView || !hostView.window) return;   // 等视图真正上屏再挂，位置才准

    UIButton *exist = objc_getAssociatedObject(vc, kPJQGBubbleKey);
    if (exist) { self.bubble = exist; return; }

    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.accessibilityIdentifier = @"pjqg_bubble";
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.72];
    b.layer.cornerRadius = 20;
    b.clipsToBounds = YES;
    [b setTitle:@"分组" forState:UIControlStateNormal];

    CGFloat w = 62, h = 40;
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
    self.bubble = b;
    objc_setAssociatedObject(vc, kPJQGBubbleKey, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PJQGLog(@"  · 悬浮球已创建");
}

- (void)refreshTitle {
    NSInteger k = PJQGDefaultKind();
    NSString *longT = (k < 0) ? @"分组" : [NSString stringWithFormat:@"分组·%@", PJQGKindName((PJQGKind)k)];
    NSString *shortT = (k < 0) ? @"分组" : PJQGKindName((PJQGKind)k);

    [self.navButton setTitle:longT forState:UIControlStateNormal];
    [self.navButton sizeToFit];
    if (self.bubble) [self.bubble setTitle:shortT forState:UIControlStateNormal];
}

#pragma mark 交互

- (void)onTap:(UIButton *)sender {
    @try {
        PJQGLog(@"[tap] 单击，默认分组=%ld", (long)PJQGDefaultKind());
        NSInteger d = PJQGDefaultKind();
        if (d < 0) { [self presentPickerSetDefault:YES]; return; }

        UIViewController *vc = self.host;
        if (!vc) return;
        NSString *how = nil;
        NSString *chatId = PJQGChatId(vc, &how);
        PJQGLog(@"[tap] 会话ID=%@ (字段 %@)", chatId ?: @"(空)", how ?: @"-");
        if (chatId.length == 0) { PJQGToast(vc.view, @"未能识别当前会话（见诊断报告）"); return; }

        NSString *detail = nil;
        PJQGApplyResult r = PJQGApply(chatId, (PJQGKind)d, &detail);
        if (r == PJQGApplyOK) {
            PJQGToast(vc.view, [NSString stringWithFormat:@"已归入：%@（默认）", PJQGKindName((PJQGKind)d)]);
        } else {
            PJQGToast(vc.view, PJQGApplyResultText(r, detail));
        }
    } @catch (NSException *e) {
        PJQGLog(@"[tap] 异常: %@", e.reason);
    }
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    @try { [self presentMenu]; } @catch (NSException *e) { PJQGLog(@"[menu] 异常: %@", e.reason); }
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    @try {
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
    } @catch (NSException *e) { }
}

#pragma mark 菜单与选择器

- (UIViewController *)topmost {
    UIViewController *vc = self.host;
    int guard = 0;
    while (vc.presentedViewController && guard++ < 8) vc = vc.presentedViewController;
    return vc;
}

- (void)presentMenu {
    UIViewController *vc = [self topmost];
    if (!vc || vc.isBeingDismissed) return;

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

    [sheet addAction:[UIAlertAction actionWithTitle:@"接口探测（只读，不写入）"
                        style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *a) { [self showDiagnose]; }]];

    [sheet addAction:[UIAlertAction actionWithTitle:
        (PJQGSafeMode() ? @"解除安全模式（允许写入）" : @"进入安全模式（禁用写入）")
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
        PJQGSetSafeMode(!PJQGSafeMode());
        PJQGToast(self.host.view, PJQGSafeMode() ? @"已进入安全模式" : @"已解除安全模式");
    }]];

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
    UIViewController *vc = [self topmost];
    if (!vc || vc.isBeingDismissed) return;

    NSString *title = setDefault ? @"选择默认分组" : @"本次归入";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                message:setDefault ? @"选择后成为默认分组，之后单击即直接归入" : nil
                                preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSInteger k = PJQGKindGroup; k <= PJQGKindOther; k++) {
        NSString *name = PJQGKindName((PJQGKind)k);
        [sheet addAction:[UIAlertAction actionWithTitle:name
                            style:UIAlertActionStyleDefault
                            handler:^(UIAlertAction *a) {
            @try {
                if (setDefault) { PJQGSetDefaultKind(k); [self refreshTitle]; }
                UIViewController *host = self.host;
                if (!host) return;
                NSString *how = nil;
                NSString *chatId = PJQGChatId(host, &how);
                if (chatId.length == 0) { PJQGToast(host.view, @"未能识别当前会话（见诊断报告）"); return; }
                NSString *detail = nil;
                PJQGApplyResult r = PJQGApply(chatId, (PJQGKind)k, &detail);
                if (r == PJQGApplyOK) {
                    PJQGToast(host.view, [NSString stringWithFormat:@"已归入：%@%@",
                                          name, setDefault ? @"（已设为默认）" : @""]);
                } else {
                    PJQGToast(host.view, PJQGApplyResultText(r, detail));
                }
            } @catch (NSException *e) {
                PJQGLog(@"[picker] 异常: %@", e.reason);
            }
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                        style:UIAlertActionStyleCancel handler:nil]];
    [self anchorPopover:sheet];
    [vc presentViewController:sheet animated:YES completion:nil];
}

- (void)showDiagnose {
    NSString *rep = nil;
    @try { rep = PJQGDiagnose(self.host); }
    @catch (NSException *e) { rep = [NSString stringWithFormat:@"生成失败: %@", e.reason]; }
    PJQGLog(@"%@", rep ?: @"(空)");

    UIViewController *vc = [self topmost];
    if (!vc) return;

    NSString *body = rep.length > 1500 ? [rep substringToIndex:1500] : rep;
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"接口探测（只读）"
                             message:body
                             preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"复制全文"
                        style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = rep;
        PJQGToast(self.host.view, @"已复制，可直接粘贴发送");
    }]];
    [al addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:al animated:YES completion:nil];
}

- (void)anchorPopover:(UIAlertController *)sheet {
    @try {
        UIPopoverPresentationController *pop = sheet.popoverPresentationController;
        if (!pop) return;
        UIView *src = self.bubble ?: self.navButton ?: self.host.view;
        if (!src) return;
        pop.sourceView = src;
        pop.sourceRect = src.bounds;
    } @catch (NSException *e) { }
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
    @try {
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
    } @catch (NSException *e) { ok = NO; }

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

static void PJQGShowLaunchAlert(void) {
    BOOL misaka = (NSClassFromString(@"PJGroupDataModel") || NSClassFromString(@"PJMisakaManager"));
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSString *risky = [ud objectForKey:kPJQGRiskyFlagKey];

    PJQGLog(@"[自检] MikotoHelper=%@ 默认=%ld 悬浮球=%@ 安全模式=%@",
            misaka ? @"✓" : @"✗", (long)PJQGDefaultKind(),
            PJQGBubbleVisible() ? @"显示" : @"隐藏", PJQGSafeMode() ? @"开" : @"关");

    if (risky.length > 0) {
        PJQGLog(@"!!! 上次运行崩溃于: %@ → 自动进入安全模式", risky);
        [ud removeObjectForKey:kPJQGRiskyFlagKey];
        [ud synchronize];
        PJQGSetSafeMode(YES);
    }

    UIWindow *kw = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.isKeyWindow) { kw = w; break; }
    }
    if (!kw) kw = UIApplication.sharedApplication.windows.firstObject;
    UIViewController *host = kw.rootViewController;
    int guard = 0;
    while (host.presentedViewController && guard++ < 8) host = host.presentedViewController;
    if (!host || host.isBeingDismissed) return;

    NSString *title = @"MikotoQuickGroup 已加载 ✓";
    NSString *msg;
    if (risky.length > 0) {
        title = @"⚠️ 上次运行发生过崩溃";
        msg = [NSString stringWithFormat:
               @"上次崩溃发生在：\n%@\n\n"
                "已自动进入安全模式（不会再调用该接口，所以不会再闪退）。\n\n"
                "崩溃调用栈已写入：\n%@\n\n"
                "请把该日志文件发给我。",
               risky, PJQGLogPath()];
    } else if (!misaka) {
        msg = [NSString stringWithFormat:
               @"插件已加载，但没检测到 MikotoHelper 的分组模块。\n"
                "请确认 MikotoHelper 也在运行。\n\n日志：%@", PJQGLogPath()];
    } else {
        msg = [NSString stringWithFormat:
               @"插件已被微信加载。\n\n"
                "进入任意聊天窗口：右侧有可拖动的「分组」悬浮球，右上角有「分组」按钮。\n"
                "单击 = 归入默认分组；长按 = 菜单（含「接口探测」「安全模式」）。\n\n"
                "日志：%@", PJQGLogPath()];
    }

    UIAlertController *al = [UIAlertController alertControllerWithTitle:title
                             message:msg preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
    [al addAction:[UIAlertAction actionWithTitle:@"不再提示" style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *a) {
        [ud setBool:YES forKey:kPJQGSilentKey];
        [ud synchronize];
    }]];
    @try { [host presentViewController:al animated:YES completion:nil]; } @catch (NSException *e) { }
}

%ctor {
    // 构造函数里只做轻量操作（不碰 NSUserDefaults），避免早期初始化死锁
    PJQGLog(@"================================================");
    PJQGLog(@"MikotoQuickGroup v1.2 已注入 (pid=%d)", getpid());
    PJQGLog(@"bundle = %@", NSBundle.mainBundle.bundleIdentifier ?: @"?");
    PJQGLog(@"MikotoHelper(Misaka) = %@",
            (NSClassFromString(@"PJGroupDataModel") || NSClassFromString(@"PJMisakaManager"))
                ? @"✓ 已检测到" : @"✗ 未检测到");
    PJQGLog(@"日志文件 = %@", PJQGLogPath());
    PJQGLog(@"================================================");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try { PJQGInstallCrashHandlers(); PJQGLog(@"[自检] 崩溃取证已启用"); }
        @catch (NSException *e) { }
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
            BOOL silent = [ud boolForKey:kPJQGSilentKey];
            BOOL risky = ([ud objectForKey:kPJQGRiskyFlagKey] != nil);
            if (silent && !risky) {
                PJQGLog(@"[自检] 用户已关闭启动提示");
            } else {
                PJQGShowLaunchAlert();
            }
        } @catch (NSException *e) {
            PJQGLog(@"[自检] 弹窗失败: %@", e.reason);
        }
    });
}
