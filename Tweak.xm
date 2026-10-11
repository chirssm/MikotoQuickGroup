// ============================================================================
//  MikotoQuickGroup v1.3  —— 微信聊天界面「快速分组」按钮
// ----------------------------------------------------------------------------
//  依赖宿主 : WeChat (com.tencent.xin) + MikotoHelper.dylib（提供 Misaka 分组能力）
//
//  v1.3 针对「按钮能点，但提示未能识别当前会话，且找不到诊断报告」的改动：
//   1. 【报告随手可得】任何失败都自动弹出全屏「诊断报告」页（可滚动/可选中/
//      一键复制），同时自动写入剪贴板并提示 —— 不再需要去文件系统里翻日志
//   2. 【报告入口】悬浮球旁边新增「诊」小按钮；长按菜单第一项即「查看诊断报告」
//   3. 【会话 ID 七级识别链】
//        ① 动态捕获（微信自己写进来的值，最可靠）
//        ② KVC 取属性
//        ③ 选择子直接调用
//        ④ 成员变量扫描（按名字打分 + 值形态打分）
//        ⑤ 逻辑控制器 / 联系人 / 会话对象链
//        ⑥ 报告里给出全部候选，人工判断
//        ⑦ 手动输入兜底
//   4. 【动态捕获】用 MSHookMessageEx（运行时 dlsym 解析，取不到则自动降级）
//      挂住 setM_nsChatName: / setChatUserName: / setM_oContact: 等 setter，
//      记录微信写入的会话 ID —— 不猜，直接拿
//   5. 【报告含 ivar 全表】即使全部解析失败，也会列出聊天窗口的全部成员变量
//      名与类型（只读名称，不读内存）+ 关键成员的取值，据此可一次改对
//   6. 【日志落点修正】优先写 App 沙盒 Documents（原来写 /var/mobile/Documents
//      在沙盒下必然失败，这正是你找不到日志的原因），并回报实际可用路径
//
//  交互约定 :
//    · 单击「分组」→ 归入默认分组；未设置默认则弹选择器并把选择存为默认
//    · 长按「分组」→ 菜单（诊断报告 / 修改默认 / 本次归入其他 / 清除默认 /
//                    接口探测 / 手动输入会话ID / 安全模式 / 悬浮球开关）
//    · 单击「诊」  → 直接打开诊断报告
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
#import <dlfcn.h>
#import <sys/utsname.h>

#pragma mark - 常量

static NSString *const kPJQGVersion          = @"1.4";
static NSString *const kPJQGDefaultKindKey   = @"pjqg_default_kind";   // NSInteger, -1 = 未设置
static NSString *const kPJQGBubbleVisibleKey = @"pjqg_bubble_visible";
static NSString *const kPJQGSilentKey        = @"pjqg_silent_alert";
static NSString *const kPJQGRiskyFlagKey     = @"pjqg_risky_open";     // 危险调用哨兵
static NSString *const kPJQGSafeModeKey      = @"pjqg_safe_mode";
static NSString *const kPJQGDeepDiagKey      = @"pjqg_deep_diag";      // 是否读取对象成员变量

static const void *kPJQGActionKey       = &kPJQGActionKey;
static const void *kPJQGBubbleKey       = &kPJQGBubbleKey;
static const void *kPJQGCapturedIdKey   = &kPJQGCapturedIdKey;
static const void *kPJQGCapturedHowKey  = &kPJQGCapturedHowKey;

static const char *kPJQGRawLogPath = "/tmp/MikotoQuickGroup_crash.log";

// 前向声明（C 函数必须先声明后使用）
static BOOL        PJQGIsClassObjectSafely(id o);
static NSString   *PJQGLogPath(void);
static void        PJQGLog(NSString *fmt, ...);
static void        PJQGToast(UIView *host, NSString *text);
static NSString   *PJQGUsrNameFromObject(id o);
static NSString   *PJQGChatId(id vc, NSString **how);
static NSString   *PJQGChatIdEx(id vc, NSString **how, NSMutableString *trace);
static NSString   *PJQGChatIdFromIvars(id obj, NSString **how);
static NSString   *PJQGIvarNameTable(id obj, NSUInteger maxLines);
static NSString   *PJQGIvarValues(id obj);
static NSString   *PJQGDiagnose(id chatVC);
static void        PJQGRememberCapturedChatId(id obj, NSString *cid, NSString *how);
static void        PJQGHookSetters(Class cls);
static BOOL        PJQGDeepDiag(void);

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

#pragma mark - 日志

static NSMutableString *gPJQGReport  = nil;
static NSString        *gPJQGLogPath = nil;
static NSString        *gPJQGLasMatchReason = nil;

// 沙盒环境下 /var/mobile/Documents 不可写（这正是之前你找不到日志的原因）。
// 依次尝试：App 沙盒 Documents → App tmp → /var/mobile/Documents → /tmp
static NSString *PJQGLogPath(void) {
    if (gPJQGLogPath) return gPJQGLogPath;

    NSMutableArray *dirs = [NSMutableArray array];
    @try {
        NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (docs.count) [dirs addObject:docs.firstObject];
        [dirs addObject:NSTemporaryDirectory()];
    } @catch (NSException *e) { }
    [dirs addObject:@"/var/mobile/Documents"];
    [dirs addObject:@"/var/mobile/Library/Preferences"];
    [dirs addObject:@"/tmp"];

    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *d in dirs) {
        if (![d isKindOfClass:NSString.class] || d.length == 0) continue;
        @try {
            if (![fm fileExistsAtPath:d]) {
                [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
            }
            if ([fm isWritableFileAtPath:d]) {
                gPJQGLogPath = [d stringByAppendingPathComponent:@"MikotoQuickGroup.log"];
                return gPJQGLogPath;
            }
        } @catch (NSException *e) { }
    }
    gPJQGLogPath = @"/tmp/MikotoQuickGroup.log";
    return gPJQGLogPath;
}

static NSString *PJQGLogPathCandidates(void) {
    NSMutableString *s = [NSMutableString string];
    NSMutableArray *dirs = [NSMutableArray array];
    @try {
        NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (docs.count) [dirs addObject:docs.firstObject];
        [dirs addObject:NSTemporaryDirectory()];
    } @catch (NSException *e) { }
    [dirs addObject:@"/var/mobile/Documents"];
    [dirs addObject:@"/tmp"];

    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *d in dirs) {
        BOOL exists = NO, writable = NO;
        @try { exists = [fm fileExistsAtPath:d]; writable = [fm isWritableFileAtPath:d]; }
        @catch (NSException *e) { }
        [s appendFormat:@"    %@  存在=%@ 可写=%@\n", d,
            exists ? @"Y" : @"N", writable ? @"Y" : @"N"];
    }
    return s;
}

static void PJQGLogWrite(NSString *line) {
    if (line.length == 0) return;
    NSLog(@"[MikotoQuickGroup] %@", line);

    if (!gPJQGReport) gPJQGReport = [NSMutableString string];
    [gPJQGReport appendFormat:@"%@\n", line];
    if (gPJQGReport.length > 60000) {
        [gPJQGReport deleteCharactersInRange:NSMakeRange(0, 20000)];
        NSRange nl = [gPJQGReport rangeOfString:@"\n"];
        if (nl.location != NSNotFound) [gPJQGReport deleteCharactersInRange:NSMakeRange(0, NSMaxRange(nl))];
    }

    @try {
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
    } @catch (NSException *e) { }
}

static void PJQGLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!s) return;
    @try { PJQGLogWrite(s); } @catch (NSException *e) { }
}

#pragma mark - 崩溃取证

static void PJQGRawWrite(const char *s) {
    if (!s) return;
    int fd = open(kPJQGRawLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
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
        int fd = open(kPJQGRawLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) { backtrace_symbols_fd(frames, n, fd); close(fd); }
    }
    PJQGRawWrite("\n--- end ---\n");

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

#pragma mark - 动态捕获的会话 ID

static NSString *gPJQGLastCapturedId  = nil;
static NSString *gPJQGLastCapturedHow = nil;

static void PJQGRememberCapturedChatId(id obj, NSString *cid, NSString *how) {
    if (!obj || cid.length == 0) return;
    @try {
        objc_setAssociatedObject(obj, kPJQGCapturedIdKey,  [cid copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(obj, kPJQGCapturedHowKey, [how copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        gPJQGLastCapturedId  = [cid copy];
        gPJQGLastCapturedHow = [how copy];
        PJQGLog(@"[capture] 会话ID = %@   via %@   on %@",
                cid, how ?: @"?", NSStringFromClass([obj class]));
    } @catch (NSException *e) { }
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

static BOOL PJQGDeepDiag(void) {
    NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kPJQGDeepDiagKey];
    return n ? n.boolValue : YES;
}

static void PJQGSetDeepDiag(BOOL v) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:v forKey:kPJQGDeepDiagKey];
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
                [UIView animateWithDuration:0.30 delay:1.60 options:0
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

static NSMutableDictionary *gPJQGSelClassCache = nil;

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

static BOOL PJQGMethodReturnsObject(id target, SEL sel) {
    Method m = PJQGGetMethod(target, sel, NULL);
    if (!m) return NO;
    char rbuf[8] = {0};
    method_getReturnType(m, rbuf, sizeof(rbuf));
    return rbuf[0] == '@';
}

static BOOL PJQGClassHasOwnMethod(Class k, SEL s) {
    if (!k || !s) return NO;
    unsigned cnt = 0;
    Method *ms = class_copyMethodList(k, &cnt);
    if (!ms) return NO;
    BOOL found = NO;
    for (unsigned i = 0; i < cnt; i++) {
        if (method_getName(ms[i]) == s) { found = YES; break; }
    }
    free(ms);
    return found;
}

#pragma mark - 验签（核心安全闸门）

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
        if (why) *why = [NSString stringWithFormat:@"参数类型 %@ → 需要该类型对象，v1.3 不硬凑，已阻止", type];
        return NO;
    }
    if (why) *why = [NSString stringWithFormat:@"参数类型 %@ → 非对象类型，已阻止", type];
    return NO;
}

#pragma mark - 会话 ID 识别（七级链）

static NSArray *PJQGChatIdKeyCandidates(void) {
    return @[ @"m_nsChatName", @"m_nsRealChatUsr", @"m_nsChatRoomUserName",
              @"chatUserName", @"m_nsUsrName", @"m_nsToUsr", @"m_nsUserName",
              @"currentChatUserName", @"m_nsChatSessionName" ];
}

static NSArray *PJQGChatIdSelCandidates(void) {
    return @[ @"m_nsChatName", @"chatUserName", @"getChatUserName",
              @"m_nsChatRoomUserName", @"m_nsRealChatUsr", @"m_nsUsrName",
              @"usrName", @"getCurrentChatUsrName", @"chatUsrName",
              @"contactUsrName", @"m_nsToUsr", @"getChatUsrName" ];
}

static NSArray *PJQGChatIdChildKeyCandidates(void) {
    return @[ @"m_logicController", @"logicController", @"m_oLogicController",
              @"logicCtrl", @"m_logicCtrl", @"viewLogicController",
              @"m_oViewLogicController", @"logic", @"m_logic",
              @"m_chatLogicController", @"chatController", @"m_controller",
              @"m_oContact", @"contact", @"m_contact", @"m_oSessionInfo",
              @"sessionInfo", @"m_sessionInfo", @"m_oSession", @"session" ];
}

static NSArray *PJQGIvarPatterns(void) {
    return @[ @"chat", @"usr", @"user", @"contact", @"session",
              @"room", @"talk", @"logic", @"friend" ];
}

static BOOL PJQGNameMatchesPatterns(NSString *low, NSArray *pats) {
    if (low.length == 0) return NO;
    for (NSString *p in pats) { if ([low containsString:p]) return YES; }
    return NO;
}

static int PJQGIvarNameScore(NSString *low) {
    if ([low containsString:@"nschatname"])       return 100;
    if ([low containsString:@"realchatusr"])      return 95;
    if ([low containsString:@"chatroomusername"]) return 92;
    if ([low containsString:@"chatusername"])     return 90;
    if ([low containsString:@"usrname"])          return 85;
    if ([low containsString:@"userName".lowercaseString]) return 70;
    if ([low containsString:@"chat"])             return 50;
    if ([low containsString:@"contact"])          return 40;
    return 20;
}

static int PJQGLooksLikeChatIdScore(NSString *s) {
    int sc = 0;
    if ([s containsString:@"@chatroom"]) sc += 50;
    if ([s hasPrefix:@"wxid_"])          sc += 40;
    if ([s hasPrefix:@"gh_"])            sc += 30;
    if ([s containsString:@"@openim"])   sc += 30;
    BOOL simple = YES;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        BOOL ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') ||
                  (c >= 'A' && c <= 'Z') || c == '_' || c == '@' || c == '.' || c == '-';
        if (!ok) { simple = NO; break; }
    }
    if (simple) sc += 15;
    return sc;
}

// 绝对安全的取值：为什么不直接用 KVC？
// 微信的 protobuf 基类把 -valueForUndefinedKey: 重写成了直接抛异常，
// 抛出来的信息就是 "Property Name should be baseResponse" 这类断言文本。
// 只要 KVC 取一个不存在的键，就会炸。所以这里：
//   ① 先查成员变量 → 有就直接 object_getIvar（完全绕过 KVC）
//   ② 只有确认类真的实现了返回对象的 getter，才走 valueForKey:
//   ③ 全过程包 @try（respondsToSelector: 会触发 +initialize，同样可能抛）
static id PJQGSafeObjectForKey(id obj, NSString *key) {
    if (!obj || key.length == 0) return nil;
    if (PJQGIsClassObjectSafely(obj)) return nil;
    @try {
        const char *kn = key.UTF8String;
        if (!kn) return nil;

        // ① 成员变量直读（class_getInstanceVariable 会自动沿继承链查找）
        Ivar iv = class_getInstanceVariable([obj class], kn);
        if (iv) {
            const char *te = ivar_getTypeEncoding(iv);
            if (!te || te[0] != '@') return nil;     // 标量成员不走这条路
            return object_getIvar(obj, iv);
        }

        // ② 确认真的有这个方法，且返回的是对象，才敢 KVC
        SEL g = NSSelectorFromString(key);
        if (!g) return nil;
        Method m = class_getInstanceMethod([obj class], g);
        if (!m) return nil;
        char rt[8] = {0};
        method_getReturnType(m, rt, sizeof(rt));
        if (rt[0] != '@') return nil;
        if (![obj respondsToSelector:g]) return nil;
        return [obj valueForKey:key];
    } @catch (NSException *e) {
        return nil;
    } @catch (...) {
        return nil;
    }
}

static NSString *PJQGSafeStringForKey(id obj, NSString *key, NSString **hitKey) {
    id v = PJQGSafeObjectForKey(obj, key);
    if ([v isKindOfClass:NSString.class] && [(NSString *)v length] > 0) {
        if (hitKey) *hitKey = key;
        return (NSString *)v;
    }
    return nil;
}

static NSString *PJQGUsrNameFromObject(id o) {
    if (!o || PJQGIsClassObjectSafely(o)) return nil;
    for (NSString *k in @[ @"m_nsUsrName", @"nsUsrName", @"usrName",
                           @"m_nsUserName", @"userName", @"m_nsChatName" ]) {
        NSString *v = PJQGSafeStringForKey(o, k, NULL);
        if (v) return v;
    }
    return nil;
}

static NSString *PJQGChatIdFromIvars(id obj, NSString **how) {
    if (!obj) return nil;
    @try {
        NSArray *pats = PJQGIvarPatterns();
        NSString *best = nil;
        NSString *bestName = nil;
        int bestScore = -1;
        int guard = 0;
        for (Class k = [obj class]; k && k != Nil && guard++ < 12; k = class_getSuperclass(k)) {
            unsigned int cnt = 0;
            Ivar *ivs = class_copyIvarList(k, &cnt);
            if (!ivs) continue;
            for (unsigned int i = 0; i < cnt; i++) {
                const char *nm = ivar_getName(ivs[i]);
                const char *tt = ivar_getTypeEncoding(ivs[i]);
                if (!nm || !tt || tt[0] != '@') continue;
                NSString *name = [NSString stringWithUTF8String:nm];
                NSString *low = name.lowercaseString;
                if (!PJQGNameMatchesPatterns(low, pats)) continue;

                id v = nil;
                @try { v = object_getIvar(obj, ivs[i]); } @catch (NSException *e) { continue; }
                if (!v || ![v isKindOfClass:NSString.class]) continue;
                NSString *sv = (NSString *)v;
                if (sv.length == 0) continue;

                int sc = PJQGIvarNameScore(low) + PJQGLooksLikeChatIdScore(sv);
                if (sc > bestScore) { bestScore = sc; best = sv; bestName = name; }
            }
            free(ivs);
        }
        if (best && how) *how = bestName;
        return best;
    } @catch (NSException *e) { return nil; }
}

// 全部 ivar 的名称与类型（只读元数据，不碰内存，绝对安全）
static NSString *PJQGIvarNameTable(id obj, NSUInteger maxLines) {
    if (!obj) return @"  (无对象)\n";
    NSMutableString *s = [NSMutableString string];
    NSUInteger n = 0;
    int guard = 0;
    for (Class k = [obj class]; k && k != Nil && guard++ < 12; k = class_getSuperclass(k)) {
        unsigned int cnt = 0;
        Ivar *ivs = class_copyIvarList(k, &cnt);
        if (!ivs) continue;
        [s appendFormat:@"  [%@] %u 个\n", NSStringFromClass(k), cnt];
        for (unsigned int i = 0; i < cnt; i++) {
            const char *nm = ivar_getName(ivs[i]);
            const char *tt = ivar_getTypeEncoding(ivs[i]);
            if (!nm) continue;
            if (n++ >= maxLines) { [s appendString:@"  ...(截断)\n"]; free(ivs); return s; }
            [s appendFormat:@"    %s : %s\n", nm, tt ? tt : "?"];
        }
        free(ivs);
    }
    if (n == 0) [s appendString:@"  (该类链无成员变量)\n"];
    return s;
}

// 关键 ivar 的取值（会读内存，受「深度诊断」开关控制 + 哨兵保护）
static NSString *PJQGIvarValues(id obj) {
    if (!obj) return @"    (无对象)\n";
    if (!PJQGDeepDiag()) return @"    (深度诊断已关闭，未读取对象成员变量)\n";
    NSMutableString *s = [NSMutableString string];
    NSArray *pats = PJQGIvarPatterns();
    NSUInteger n = 0;
    int guard = 0;
    PJQGRiskyBegin("diag.ivar");
    for (Class k = [obj class]; k && k != Nil && guard++ < 12; k = class_getSuperclass(k)) {
        unsigned int cnt = 0;
        Ivar *ivs = class_copyIvarList(k, &cnt);
        if (!ivs) continue;
        for (unsigned int i = 0; i < cnt; i++) {
            const char *nm = ivar_getName(ivs[i]);
            const char *tt = ivar_getTypeEncoding(ivs[i]);
            if (!nm || !tt || tt[0] != '@') continue;
            NSString *name = [NSString stringWithUTF8String:nm];
            if (!PJQGNameMatchesPatterns(name.lowercaseString, pats)) continue;

            @try {
                id v = object_getIvar(obj, ivs[i]);
                if (!v)                                   [s appendFormat:@"    %@ = (nil)\n", name];
                else if ([v isKindOfClass:NSString.class]) [s appendFormat:@"    %@ = \"%@\"\n", name, v];
                else                                       [s appendFormat:@"    %@ : %@\n", name, NSStringFromClass([v class])];
                n++;
            } @catch (NSException *e) {
                [s appendFormat:@"    %@ = <读取异常>\n", name];
            }
            if (n > 80) {
                [s appendString:@"    ...(截断)\n"];
                free(ivs);
                PJQGRiskyEnd();
                return s;
            }
        }
        free(ivs);
    }
    PJQGRiskyEnd();
    if (n == 0) [s appendString:@"    (无匹配的成员变量)\n"];
    return s;
}

static NSString *PJQGIvarHasName(id obj, NSString *fragment) {
    if (!obj || fragment.length == 0) return nil;
    NSString *lowFrag = fragment.lowercaseString;
    int guard = 0;
    for (Class k = [obj class]; k && k != Nil && guard++ < 12; k = class_getSuperclass(k)) {
        unsigned int cnt = 0;
        Ivar *ivs = class_copyIvarList(k, &cnt);
        if (!ivs) continue;
        for (unsigned int i = 0; i < cnt; i++) {
            const char *nm = ivar_getName(ivs[i]);
            if (!nm) continue;
            NSString *name = [NSString stringWithUTF8String:nm];
            if ([name.lowercaseString containsString:lowFrag]) { free(ivs); return name; }
        }
        free(ivs);
    }
    return nil;
}

static NSString *PJQGChatIdEx(id vc, NSString **how, NSMutableString *trace) {
    if (how) *how = nil;
    if (!vc) return nil;
    NSArray *kvcKeys = PJQGChatIdKeyCandidates();
    NSArray *selNames = PJQGChatIdSelCandidates();

    // ① 动态捕获
    @try {
        id cap = objc_getAssociatedObject(vc, kPJQGCapturedIdKey);
        if ([cap isKindOfClass:NSString.class] && [(NSString *)cap length] > 0) {
            NSString *h = objc_getAssociatedObject(vc, kPJQGCapturedHowKey);
            if (how) *how = [NSString stringWithFormat:@"动态捕获(%@)", h ?: @"?"];
            if (trace) [trace appendFormat:@"  ① 动态捕获 = %@  ✓\n", cap];
            return cap;
        }
    } @catch (NSException *e) { }
    if (trace) [trace appendString:@"  ① 动态捕获 = (无)\n"];

    // ② KVC
    for (NSString *k in kvcKeys) {
        NSString *v = PJQGSafeStringForKey(vc, k, NULL);
        if (trace) [trace appendFormat:@"  ② KVC %@ = %@\n", k, v ?: @"(无)"];
        if (v) { if (how) *how = [NSString stringWithFormat:@"KVC %@", k]; return v; }
    }

    // ③ 选择子探测
    for (NSString *sn in selNames) {
        SEL s = NSSelectorFromString(sn);
        @try {
            if (![vc respondsToSelector:s]) continue;
            if (!PJQGMethodReturnsObject(vc, s)) continue;
            id v = ((id (*)(id, SEL))objc_msgSend)(vc, s);
            if ([v isKindOfClass:NSString.class] && [(NSString *)v length] > 0) {
                if (trace) [trace appendFormat:@"  ③ 选择子 %@ = %@  ✓\n", sn, v];
                if (how) *how = [NSString stringWithFormat:@"选择子 %@", sn];
                return v;
            }
        } @catch (NSException *e) {
            if (trace) [trace appendFormat:@"  ③ 选择子 %@ → 调用异常\n", sn];
        }
    }
    if (trace) [trace appendString:@"  ③ 选择子探测 = (无)\n"];

    // ④ 成员变量扫描
    NSString *ivHow = nil;
    NSString *iv = PJQGChatIdFromIvars(vc, &ivHow);
    if (trace) [trace appendFormat:@"  ④ 成员变量扫描 = %@\n",
                iv ? [NSString stringWithFormat:@"\"%@\" (%@)", iv, ivHow] : @"(无)"];
    if (iv) { if (how) *how = [NSString stringWithFormat:@"成员变量 %@", ivHow]; return iv; }

    // ⑤ 子对象链（逻辑控制器 / 联系人 / 会话对象）
    for (NSString *h in PJQGChatIdChildKeyCandidates()) {
        id child = PJQGSafeObjectForKey(vc, h);
        if (!child || PJQGIsClassObjectSafely(child)) continue;

        @try {
            id cap = objc_getAssociatedObject(child, kPJQGCapturedIdKey);
            if ([cap isKindOfClass:NSString.class] && [(NSString *)cap length] > 0) {
                if (how) *how = [NSString stringWithFormat:@"%@.动态捕获", h];
                if (trace) [trace appendFormat:@"  ⑤ %@ → 动态捕获 = %@  ✓\n", h, cap];
                return cap;
            }
        } @catch (NSException *e) { }

        for (NSString *k in kvcKeys) {
            NSString *v = PJQGSafeStringForKey(child, k, NULL);
            if (v) {
                if (how) *how = [NSString stringWithFormat:@"%@.%@", h, k];
                if (trace) [trace appendFormat:@"  ⑤ %@.%@ = %@  ✓\n", h, k, v];
                return v;
            }
        }

        NSString *c2 = PJQGChatIdFromIvars(child, &ivHow);
        if (c2) {
            if (how) *how = [NSString stringWithFormat:@"%@.ivar.%@", h, ivHow];
            if (trace) [trace appendFormat:@"  ⑤ %@ ivar %@ = %@  ✓\n", h, ivHow, c2];
            return c2;
        }
        if (trace) [trace appendFormat:@"  ⑤ %@ (%@) = 未取到\n", h, NSStringFromClass([child class])];
    }

    // ⑥ 全局兜底 —— 只提示不自动使用（避免分错会话）
    if (trace) {
        if (gPJQGLastCapturedId.length)
            [trace appendFormat:@"  ⑥ 全局捕获过 = %@ (%@)  ← 仅提示，不自动使用\n",
                gPJQGLastCapturedId, gPJQGLastCapturedHow ?: @"?"];
        else
            [trace appendString:@"  ⑥ 全局捕获 = (无)\n"];
    }
    return nil;
}

static NSString *PJQGChatId(id vc, NSString **how) {
    return PJQGChatIdEx(vc, how, nil);
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

        // 注意：respondsToSelector: 会触发该类的 +initialize，而 +initialize 里可能抛异常
        // （MikotoHelper 的类会去碰微信的 protobuf 对象）。整个探测循环必须包 @try。
        @try {
            for (NSString *g in @[ @"sharedInstance", @"sharedManager", @"defaultManager", @"shared",
                                   @"manager", @"defaultInstance", @"instance", @"getInstance",
                                   @"sharedModel", @"sharedDataModel", @"currentManager" ]) {
                SEL gs = NSSelectorFromString(g);
                if (!gs || ![c respondsToSelector:gs]) continue;
                id inst = ((id (*)(id, SEL))objc_msgSend)(c, gs);
                if (inst && !PJQGIsClassObjectSafely(inst) && [inst respondsToSelector:sel]) {
                    if (howFound) *howFound = [NSString stringWithFormat:@"单例 +[%@ %@]", cn, g];
                    gPJQGProviderCache[key] = inst;
                    return inst;
                }
            }
        } @catch (NSException *e) {
            PJQGLog(@"[provider] +[%@ …] 探测异常: %@", cn, e.reason ?: e.name);
        } @catch (...) {
            PJQGLog(@"[provider] +[%@ …] 探测到非 Objective-C 异常", cn);
        }
    }
    gPJQGProviderCache[key] = [NSNull null];
    return nil;
}

#pragma mark - 实际写入

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
        case PJQGApplyNoProvider:   return @"失败：未找到分组接口";
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
    PJQGLog(@"[apply] 目标选择子 = %@  会话ID = %@", selName, chatId);

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

    SEL rebuild = NSSelectorFromString(@"rebuildMainSessions");
    NSString *how2 = nil;
    id rb = PJQGFindProvider(rebuild, &how2);
    if (rb) {
        NSString *why2 = nil;
        if (PJQGSignatureAllows0(rb, rebuild, &why2)) {
            PJQGRiskyBegin("rebuildMainSessions");
            @try {
                ((void (*)(id, SEL))objc_msgSend)(rb, rebuild);
                PJQGLog(@"[apply] 已刷新 via %@", how2 ?: @"-");
            } @catch (NSException *e) { PJQGLog(@"[apply] 刷新异常: %@", e.reason); }
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

static NSString *PJQGDiagnoseDetail(id chatVC) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"======== MikotoQuickGroup 诊断报告 v%@ ========\n", kPJQGVersion];
    [s appendFormat:@"时间     : %@\n", [NSDate date]];
    [s appendFormat:@"设备     : %@\n", PJQGDeviceName()];
    [s appendFormat:@"PID      : %d\n", getpid()];
    [s appendFormat:@"Bundle   : %@\n", NSBundle.mainBundle.bundleIdentifier ?: @"?"];
    [s appendFormat:@"WeChat   : %@ (%@)\n",
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?"];
    [s appendFormat:@"安全模式 : %@\n", PJQGSafeMode() ? @"开启" : @"关闭"];
    [s appendFormat:@"深度诊断 : %@\n", PJQGDeepDiag() ? @"开启" : @"关闭"];
    [s appendFormat:@"上次崩溃点: %@\n", [ud objectForKey:kPJQGRiskyFlagKey] ?: @"(无)"];
    [s appendFormat:@"实际日志 : %@\n", PJQGLogPath()];
    [s appendString:@"日志落点候选（为何你找不到日志）:\n"];
    [s appendString:PJQGLogPathCandidates()];

    [s appendString:@"\n--- MikotoHelper 是否已加载 ---\n"];
    for (NSString *cn in @[ @"PJGroupDataModel", @"PJMisakaManager", @"PJGroupManager",
                            @"PJManagerModel", @"PJHelper", @"PJPluginModel",
                            @"PJGroupModel", @"PJSettingGroupVC" ]) {
        [s appendFormat:@"  %@ : %@\n", cn, NSClassFromString(cn) ? @"✓ 存在" : @"✗ 不存在"];
    }

    [s appendString:@"\n--- 谁实现了这些方法 ---\n"];
    for (NSString *sn in @[ @"addGroupData:", @"addChatData:", @"addOtherGroupData:",
                            @"misaka_selectChatAction", @"rebuildMainSessions",
                            @"chatIsChatAction:", @"groupIsChatAction:",
                            @"MisakaGroupCreateWithSection:WithLogicController:WithDataSource:WithGroupDic:WithChatDic:WithOtherGroup:" ]) {
        NSArray *cls = PJQGClassesImplementing(NSSelectorFromString(sn));
        [s appendFormat:@"  %@\n      [%lu] %@\n", sn, (unsigned long)cls.count,
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
        [s appendFormat:@"  %@\n      %@  via %@\n", sn,
            p ? NSStringFromClass([p class]) : @"(未找到)", how ?: @"-"];
    }

    [s appendString:@"\n--- PJ* 类清单 ---\n"];
    NSArray *pj = PJQGClassNamesWithPrefix(@"PJ");
    [s appendFormat:@"  PJ* 共 %lu 个\n", (unsigned long)pj.count];
    for (NSString *prefix in @[ @"PJGroup", @"PJMisaka", @"PJTag", @"PJHelper", @"PJUtils", @"PJSetting" ]) {
        NSMutableArray *hit = [NSMutableArray array];
        for (NSString *n in pj) if ([n hasPrefix:prefix]) [hit addObject:n];
        if (hit.count) [s appendFormat:@"  %@: %@\n", prefix, [hit componentsJoinedByString:@", "]];
    }

    [s appendString:@"\n--- 当前聊天窗口 ---\n"];
    if (chatVC) {
        [s appendFormat:@"  类名: %@\n", NSStringFromClass([chatVC class])];
        [s appendFormat:@"  匹配原因: %@\n", gPJQGLasMatchReason ?: @"?"];
        [s appendFormat:@"  动态捕获: %@ (%@)\n",
            objc_getAssociatedObject(chatVC, kPJQGCapturedIdKey) ?: @"(无)",
            objc_getAssociatedObject(chatVC, kPJQGCapturedHowKey) ?: @"-"];
        NSMutableString *tr = [NSMutableString string];
        NSString *how = nil;
        NSString *cid = PJQGChatIdEx(chatVC, &how, tr);
        [s appendString:@"  识别过程:\n"];
        [s appendString:tr];
        [s appendFormat:@"  ⇒ 结果: %@  (来源 %@)\n\n", cid ?: @"(未取到)", how ?: @"-"];

        [s appendString:@"  成员变量名称全表（只读元数据，可据此定位会话ID字段）:\n"];
        [s appendString:PJQGIvarNameTable(chatVC, 260)];

        [s appendString:@"  关键成员取值:\n"];
        [s appendString:PJQGIvarValues(chatVC)];

        NSString *logicIvar = PJQGIvarHasName(chatVC, @"logic");
        NSString *contactIvar = PJQGIvarHasName(chatVC, @"contact");
        [s appendFormat:@"  线索: logic 成员=%@  contact 成员=%@\n",
            logicIvar ?: @"(无)", contactIvar ?: @"(无)"];
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

    [s appendString:@"\n--- 最近日志（内存缓存） ---\n"];
    if (gPJQGReport.length) {
        NSString *tail = gPJQGReport;
        if (tail.length > 6000) tail = [tail substringFromIndex:(tail.length - 6000)];
        [s appendFormat:@"%@\n", tail];
    } else {
        [s appendString:@"(空)\n"];
    }
    [s appendString:@"======== 报告结束 ========\n"];
    return s;
}

// ---------------- 保证能出报告 ----------------
// 上一版的问题：完整报告里只要有一条语句抛异常（微信的 protobuf 基类把
// -valueForUndefinedKey: 重写成直接抛异常，信息形如 "Property Name should be baseResponse"），
// 整份报告就只剩一行错误，什么线索都拿不到。
// 现在改成两段式：先输出一份「全部走运行时元数据、绝不抛异常」的最小报告（含成员变量名称全表），
// 再尽力追加完整报告；完整报告炸了也不影响前面那部分。

static NSString *PJQGDiagnoseMini(id chatVC) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"======== MikotoQuickGroup 诊断报告 v%@ ========\n", kPJQGVersion];
    @try { [s appendFormat:@"时间     : %@\n", [NSDate date]]; } @catch (NSException *e) { }
    @try { [s appendFormat:@"设备     : %@\n", PJQGDeviceName()]; } @catch (NSException *e) { }
    @try { [s appendFormat:@"PID      : %d\n", getpid()]; } @catch (NSException *e) { }
    @try { [s appendFormat:@"Bundle   : %@\n", NSBundle.mainBundle.bundleIdentifier ?: @"?"]; }
    @catch (NSException *e) { }
    @try {
        [s appendFormat:@"WeChat   : %@ (%@)\n",
            [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
            [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?"];
    } @catch (NSException *e) { }
    @try {
        [s appendFormat:@"安全模式 : %@   深度诊断 : %@\n",
            PJQGSafeMode() ? @"开启" : @"关闭", PJQGDeepDiag() ? @"开启" : @"关闭"];
    } @catch (NSException *e) { }
    @try {
        [s appendFormat:@"上次崩溃点: %@\n",
            [NSUserDefaults.standardUserDefaults objectForKey:kPJQGRiskyFlagKey] ?: @"(无)"];
    } @catch (NSException *e) { }
    @try { [s appendFormat:@"实际日志 : %@\n", PJQGLogPath()]; } @catch (NSException *e) { }
    @try { [s appendString:@"日志落点候选:\n"]; [s appendString:PJQGLogPathCandidates()]; }
    @catch (NSException *e) { }

    // ★ 最关键的定位信息：当前聊天窗口的成员变量名称与类型全表
    //   纯运行时元数据（不读对象内存、不发消息给未知类），绝对不会抛异常
    @try {
        [s appendString:@"\n--- 当前聊天窗口（元数据，保证输出） ---\n"];
        if (chatVC) {
            [s appendFormat:@"  类名: %@\n", NSStringFromClass([chatVC class])];
            [s appendFormat:@"  匹配原因: %@\n", gPJQGLasMatchReason ?: @"?"];
            [s appendFormat:@"  动态捕获: %@ (%@)\n",
                objc_getAssociatedObject(chatVC, kPJQGCapturedIdKey) ?: @"(无)",
                objc_getAssociatedObject(chatVC, kPJQGCapturedHowKey) ?: @"-"];
            [s appendString:@"  成员变量名称全表:\n"];
            [s appendString:PJQGIvarNameTable(chatVC, 320)];
        } else {
            [s appendString:@"  (尚未进入聊天窗口)\n"];
        }
    } @catch (NSException *e) {
        [s appendFormat:@"  ⚠︎ 元数据段异常: %@\n", e.reason];
    }

    // MikotoHelper 类探测：NSClassFromString 只查表，不触发 +initialize，安全
    @try {
        [s appendString:@"\n--- MikotoHelper 是否已加载 ---\n"];
        for (NSString *cn in @[ @"PJGroupDataModel", @"PJMisakaManager", @"PJGroupManager",
                                @"PJManagerModel", @"PJHelper", @"PJPluginModel",
                                @"PJGroupModel", @"PJSettingGroupVC" ]) {
            [s appendFormat:@"  %@ : %@\n", cn, NSClassFromString(cn) ? @"✓ 存在" : @"✗ 不存在"];
        }
    } @catch (NSException *e) { }
    return s;
}

static NSString *PJQGDiagnose(id chatVC) {
    NSMutableString *out = [NSMutableString string];

    @try { [out appendString:PJQGDiagnoseMini(chatVC)]; }
    @catch (NSException *e) { [out appendFormat:@"(最小报告也失败了: %@)\n", e.reason]; }

    [out appendString:@"\n\n########## 完整报告（尽力输出） ##########\n"];
    @try {
        [out appendString:PJQGDiagnoseDetail(chatVC)];
    } @catch (NSException *e) {
        [out appendFormat:
            @"⚠︎ 完整报告在此处中断: %@\n"
             "（不影响上面「元数据」部分 —— 定位会话 ID 字段所需的信息已经在里面了，直接发我即可）\n",
            e.reason ?: e.name];
    } @catch (...) {
        [out appendString:@"⚠︎ 完整报告中断：非 Objective-C 异常\n"];
    }
    return out;
}

#pragma mark - 诊断报告页（全屏，可选中/复制）

@interface PJQGReportViewController : UIViewController
@property (nonatomic, copy) NSString *reportText;
@property (nonatomic, assign) BOOL autoCopy;
@property (nonatomic, copy) void (^onManualInput)(void);
@end

@interface PJQGReportViewController ()
- (UIButton *)makeButton:(NSString *)title action:(SEL)sel;
- (void)localToast:(NSString *)msg;
- (void)onCopy;
- (void)onShare;
- (void)onManual;
- (void)onClose;
@end

@implementation PJQGReportViewController {
    UILabel      *_title;
    UITextView   *_tv;
    UIStackView  *_bar;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (@available(iOS 13.0, *)) self.view.backgroundColor = UIColor.systemBackgroundColor;
    else                          self.view.backgroundColor = UIColor.whiteColor;

    _title = [[UILabel alloc] init];
    _title.text = @"MikotoQuickGroup 诊断报告";
    _title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _title.textAlignment = NSTextAlignmentCenter;
    if (@available(iOS 13.0, *)) _title.textColor = UIColor.labelColor;
    else                          _title.textColor = UIColor.blackColor;
    [self.view addSubview:_title];

    _tv = [[UITextView alloc] init];
    _tv.editable = NO;
    _tv.selectable = YES;
    _tv.alwaysBounceVertical = YES;
    _tv.text = self.reportText ?: @"";
    UIFont *mono = nil;
    if (@available(iOS 13.0, *)) mono = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    if (!mono) mono = [UIFont fontWithName:@"Menlo" size:10.5];
    if (!mono) mono = [UIFont systemFontOfSize:10.5];
    _tv.font = mono;
    if (@available(iOS 13.0, *)) {
        _tv.textColor = UIColor.labelColor;
        _tv.backgroundColor = UIColor.secondarySystemBackgroundColor;
    } else {
        _tv.textColor = UIColor.blackColor;
        _tv.backgroundColor = [UIColor colorWithWhite:0.96 alpha:1.0];
    }
    _tv.layer.cornerRadius = 8;
    _tv.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    _tv.layer.borderColor = [UIColor colorWithWhite:0.7 alpha:0.5].CGColor;
    [self.view addSubview:_tv];

    NSMutableArray *btns = [NSMutableArray array];
    [btns addObject:[self makeButton:@"复制全文" action:@selector(onCopy)]];
    [btns addObject:[self makeButton:@"分享"     action:@selector(onShare)]];
    if (self.onManualInput) {
        [btns addObject:[self makeButton:@"输入会话ID" action:@selector(onManual)]];
    }
    [btns addObject:[self makeButton:@"关闭" action:@selector(onClose)]];

    _bar = [[UIStackView alloc] initWithArrangedSubviews:btns];
    _bar.axis = UILayoutConstraintAxisHorizontal;
    _bar.distribution = UIStackViewDistributionFillEqually;
    _bar.spacing = 8;
    [self.view addSubview:_bar];
}

- (UIButton *)makeButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    b.layer.cornerRadius = 8;
    b.clipsToBounds = YES;
    if (@available(iOS 13.0, *)) b.backgroundColor = UIColor.tertiarySystemFillColor;
    else                          b.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1.0];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.autoCopy) {
        self.autoCopy = NO;
        @try {
            UIPasteboard.generalPasteboard.string = self.reportText ?: @"";
            [self localToast:@"诊断报告已复制到剪贴板，可直接粘贴发送"];
        } @catch (NSException *e) { }
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    CGFloat safeTop = 20, safeBottom = 0;
    if (@available(iOS 11.0, *)) {
        safeTop = MAX(self.view.safeAreaInsets.top, 20);
        safeBottom = self.view.safeAreaInsets.bottom;
    }
    CGFloat pad = 10, titleH = 38, barH = 42;
    _title.frame = CGRectMake(pad, safeTop, b.size.width - pad * 2, titleH);
    CGFloat tvY = safeTop + titleH;
    CGFloat tvH = b.size.height - tvY - barH - safeBottom - pad * 2;
    if (tvH < 120) tvH = 120;
    _tv.frame  = CGRectMake(pad, tvY, b.size.width - pad * 2, tvH);
    _bar.frame = CGRectMake(pad, tvY + tvH + pad, b.size.width - pad * 2, barH);
}

- (void)localToast:(NSString *)msg {
    UILabel *l = [[UILabel alloc] init];
    l.text = msg;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    l.textAlignment = NSTextAlignmentCenter;
    l.numberOfLines = 0;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    l.layer.cornerRadius = 9;
    l.clipsToBounds = YES;
    CGSize sz = [l sizeThatFits:CGSizeMake(self.view.bounds.size.width - 60, CGFLOAT_MAX)];
    l.frame = CGRectMake(0, 0, sz.width + 30, sz.height + 20);
    l.center = CGPointMake(self.view.bounds.size.width / 2, self.view.bounds.size.height * 0.85);
    [self.view addSubview:l];
    [UIView animateWithDuration:0.25 delay:2.0 options:0 animations:^{ l.alpha = 0; }
                     completion:^(BOOL f) { [l removeFromSuperview]; }];
}

- (void)onCopy {
    @try {
        UIPasteboard.generalPasteboard.string = self.reportText ?: @"";
        [self localToast:@"已复制全部内容"];
    } @catch (NSException *e) { }
}

- (void)onShare {
    @try {
        UIActivityViewController *a =
            [[UIActivityViewController alloc] initWithActivityItems:@[self.reportText ?: @""]
                                              applicationActivities:nil];
        if (@available(iOS 8.0, *)) {
            a.popoverPresentationController.sourceView = self.view;
            a.popoverPresentationController.sourceRect = _bar ? _bar.frame : self.view.bounds;
        }
        [self presentViewController:a animated:YES completion:nil];
    } @catch (NSException *e) { }
}

- (void)onManual {
    void (^cb)(void) = self.onManualInput;
    [self dismissViewControllerAnimated:YES completion:^{ if (cb) cb(); }];
}

- (void)onClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - 报告与手动输入的呈现

// 找出当前真正能 present 的 VC（hint 已失效则退回 keyWindow 根 VC）
static UIViewController *PJQGTopPresentableVC(UIViewController *hint) {
    UIViewController *host = nil;
    @try { if (hint && hint.view.window) host = hint; } @catch (NSException *e) { }
    if (!host) {
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.isKeyWindow) { host = w.rootViewController; break; }
        }
    }
    if (!host) {
        UIWindow *w = UIApplication.sharedApplication.windows.firstObject;
        host = w.rootViewController;
    }
    int guard = 0;
    while (host.presentedViewController && guard++ < 8) {
        if (host.presentedViewController.isBeingDismissed) break;
        host = host.presentedViewController;
    }
    if (!host) return nil;
    if (host.isBeingDismissed) {
        UIViewController *p = host.presentingViewController;
        if (p) return p;
    }
    return host;
}

static void PJQGShowReport(UIViewController *from, NSString *text, BOOL autoCopy, void (^onManual)(void)) {
    // 延迟 0.35s：给刚刚被 dismiss 的 ActionSheet / 弹窗留出收起时间，避免 present 冲突
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            UIViewController *host = PJQGTopPresentableVC(from);
            if (!host) return;
            if ([host isKindOfClass:[PJQGReportViewController class]]) return;

            PJQGReportViewController *r = [[PJQGReportViewController alloc] init];
            r.reportText   = text ?: @"(空)";
            r.autoCopy     = autoCopy;
            r.onManualInput = onManual;
            r.modalPresentationStyle = UIModalPresentationFullScreen;
            [host presentViewController:r animated:YES completion:nil];
        } @catch (NSException *e) {
            PJQGLog(@"[report] 弹出失败: %@", e.reason);
        }
    });
}

static void PJQGShowReportForHost(UIViewController *host, BOOL autoCopy, void (^onManual)(void)) {
    NSString *rep = nil;
    @try { rep = PJQGDiagnose(host); }
    @catch (NSException *e) { rep = [NSString stringWithFormat:@"生成诊断报告失败: %@", e.reason]; }
    PJQGLog(@"[report] 生成完毕，长度 %lu", (unsigned long)rep.length);
    if (autoCopy) {
        @try { UIPasteboard.generalPasteboard.string = rep ?: @""; } @catch (NSException *e) { }
    }
    PJQGShowReport(host, rep, autoCopy, onManual);
}

// 手动输入会话 ID
static void PJQGRequestManualChatId(UIViewController *from, void (^done)(NSString *chatId)) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            UIViewController *host = PJQGTopPresentableVC(from);
            if (!host) return;

            UIAlertController *al = [UIAlertController
                alertControllerWithTitle:@"手动输入会话 ID"
                message:@"例如 wxid_xxx / xxxxx@chatroom / gh_xxx\n（可从诊断报告的「关键成员取值」里复制）"
                preferredStyle:UIAlertControllerStyleAlert];

            __block UITextField *tfRef = nil;
            [al addTextFieldWithConfigurationHandler:^(UITextField *tf) {
                tfRef = tf;
                tf.placeholder = @"会话 ID";
                tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
                tf.autocorrectionType = UITextAutocorrectionTypeNo;
                tf.clearButtonMode = UITextFieldViewModeWhileEditing;
            }];

            [al addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault
                                handler:^(UIAlertAction *a) {
                NSString *t = tfRef.text ?: @"";
                t = [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (done) done(t.length ? t : nil);
            }]];
            [al addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                handler:^(UIAlertAction *a) { if (done) done(nil); }]];
            [host presentViewController:al animated:YES completion:nil];
        } @catch (NSException *e) {
            PJQGLog(@"[manual] 弹出失败: %@", e.reason);
        }
    });
}

#pragma mark - 按钮行为控制器

@interface PJQGChatAction : NSObject
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, weak) UIButton *navButton;
@property (nonatomic, weak) UIButton *bubble;
@property (nonatomic, weak) UIView   *bubbleBox;
@property (nonatomic, assign) BOOL diagnosed;
+ (instancetype)actionFor:(UIViewController *)vc;
- (void)install;
- (void)refreshTitle;
@end

@interface PJQGChatAction ()
- (void)installNavButton:(UIViewController *)vc;
- (void)installBubble:(UIViewController *)vc;
- (void)onTap:(UIButton *)sender;
- (void)onDiagTap:(UIButton *)sender;
- (void)onLongPress:(UILongPressGestureRecognizer *)g;
- (void)onPan:(UIPanGestureRecognizer *)g;
- (void)applyChatId:(NSString *)chatId kind:(PJQGKind)kind setDefault:(BOOL)setDefault;
- (void)reportForMissingChatId;
- (void)showReportAutoCopy:(BOOL)autoCopy;
- (void)manualInput;
- (UIViewController *)topmost;
- (void)presentMenu;
- (void)presentPickerSetDefault:(BOOL)setDefault;
- (void)presentKindChooserForManualId:(NSString *)chatId;
- (void)anchorPopover:(UIAlertController *)sheet;
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
    UIView *hostView = vc.view;
    UIButton *exist = objc_getAssociatedObject(vc, kPJQGBubbleKey);

    if (!PJQGBubbleVisible()) {
        UIView *box = objc_getAssociatedObject(vc, kPJQGBubbleKey);
        [box removeFromSuperview];
        objc_setAssociatedObject(vc, kPJQGBubbleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        self.bubble = nil;
        self.bubbleBox = nil;
        return;
    }
    if (!hostView || !hostView.window) return;   // 等视图真正上屏再挂，位置才准
    if (exist) {
        self.bubble = exist;
        self.bubbleBox = (UIView *)exist;
        return;
    }

    CGFloat bw = 58, dh = 40, h = 40, gap = 6;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, bw + gap + dh, h)];
    box.backgroundColor = [UIColor clearColor];

    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.accessibilityIdentifier = @"pjqg_bubble";
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.72];
    b.layer.cornerRadius = 20;
    b.clipsToBounds = YES;
    [b setTitle:@"分组" forState:UIControlStateNormal];
    b.frame = CGRectMake(0, 0, bw, h);
    [b addTarget:self action:@selector(onTap:) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    lp.minimumPressDuration = 0.45;
    [b addGestureRecognizer:lp];
    [box addSubview:b];

    UIButton *db = [UIButton buttonWithType:UIButtonTypeSystem];
    db.accessibilityIdentifier = @"pjqg_diag";
    db.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [db setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    db.backgroundColor = [UIColor colorWithRed:0.16 green:0.44 blue:0.86 alpha:0.80];
    db.layer.cornerRadius = 20;
    db.clipsToBounds = YES;
    [db setTitle:@"诊" forState:UIControlStateNormal];
    db.frame = CGRectMake(bw + gap, 0, dh, h);
    [db addTarget:self action:@selector(onDiagTap:) forControlEvents:UIControlEventTouchUpInside];
    [box addSubview:db];

    CGFloat top = 110;
    if (@available(iOS 11.0, *)) top = hostView.safeAreaInsets.top + 70;
    box.frame = CGRectMake(hostView.bounds.size.width - box.bounds.size.width - 8, top,
                           box.bounds.size.width, h);
    box.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [box addGestureRecognizer:pan];

    [hostView addSubview:box];
    self.bubble = b;
    self.bubbleBox = box;
    objc_setAssociatedObject(vc, kPJQGBubbleKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PJQGLog(@"  · 悬浮球 + 诊断按钮已创建");
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
        PJQGLog(@"[tap] 会话ID=%@ (来源 %@)", chatId ?: @"(空)", how ?: @"-");
        if (chatId.length == 0) { [self reportForMissingChatId]; return; }

        [self applyChatId:chatId kind:(PJQGKind)d setDefault:NO];
    } @catch (NSException *e) {
        PJQGLog(@"[tap] 异常: %@", e.reason);
    }
}

- (void)onDiagTap:(UIButton *)sender {
    [self showReportAutoCopy:YES];
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

#pragma mark 执行

- (void)applyChatId:(NSString *)chatId kind:(PJQGKind)kind setDefault:(BOOL)setDefault {
    UIViewController *host = self.host;
    if (!host) return;
    if (setDefault) { PJQGSetDefaultKind(kind); [self refreshTitle]; }

    NSString *detail = nil;
    PJQGApplyResult r = PJQGApply(chatId, kind, &detail);
    if (r == PJQGApplyOK) {
        PJQGToast(host.view, [NSString stringWithFormat:@"已归入：%@%@",
                              PJQGKindName(kind), setDefault ? @"（已设为默认）" : @""]);
        return;
    }
    PJQGToast(host.view, PJQGApplyResultText(r, detail));
    // 失败：半秒后自动弹报告，方便直接复制发回
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self showReportAutoCopy:YES]; });
}

- (void)reportForMissingChatId {
    UIViewController *host = self.host;
    if (host.view) PJQGToast(host.view, @"未能识别当前会话，已生成诊断报告（可手填会话ID）");
    __weak PJQGChatAction *ws = self;
    PJQGShowReportForHost(host, YES, ^{
        PJQGChatAction *ss = ws;
        if (ss) [ss manualInput];
    });
}

- (void)showReportAutoCopy:(BOOL)autoCopy {
    __weak PJQGChatAction *ws = self;
    PJQGShowReportForHost(self.host, autoCopy, ^{
        PJQGChatAction *ss = ws;
        if (ss) [ss manualInput];
    });
}

- (void)manualInput {
    __weak PJQGChatAction *ws = self;
    UIViewController *from = [self topmost] ?: self.host;
    PJQGRequestManualChatId(from, ^(NSString *chatId) {
        PJQGChatAction *ss = ws;
        if (!ss || chatId.length == 0) return;
        UIViewController *t = [ss topmost];
        if ([t isKindOfClass:[PJQGReportViewController class]]) {
            [t dismissViewControllerAnimated:YES completion:nil];
        }
        NSInteger d = PJQGDefaultKind();
        if (d < 0) { [ss presentKindChooserForManualId:chatId]; return; }
        [ss applyChatId:chatId kind:(PJQGKind)d setDefault:NO];
    });
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

    [sheet addAction:[UIAlertAction actionWithTitle:@"查看诊断报告（可复制）"
                        style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *a) { [self showReportAutoCopy:YES]; }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"手动输入会话 ID…"
                        style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *a) { [self manualInput]; }]];

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

    [sheet addAction:[UIAlertAction actionWithTitle:
        (PJQGSafeMode() ? @"解除安全模式（允许写入）" : @"进入安全模式（禁用写入）")
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
        PJQGSetSafeMode(!PJQGSafeMode());
        PJQGToast(self.host.view, PJQGSafeMode() ? @"已进入安全模式" : @"已解除安全模式");
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:
        (PJQGDeepDiag() ? @"关闭深度诊断（不读对象成员）" : @"开启深度诊断")
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
        PJQGSetDeepDiag(!PJQGDeepDiag());
        PJQGToast(self.host.view, PJQGDeepDiag() ? @"深度诊断已开启" : @"深度诊断已关闭");
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
                UIViewController *host = self.host;
                if (!host) return;
                NSString *how = nil;
                NSString *chatId = PJQGChatId(host, &how);
                PJQGLog(@"[picker] 会话ID=%@ (来源 %@)", chatId ?: @"(空)", how ?: @"-");
                if (chatId.length == 0) { [self reportForMissingChatId]; return; }
                [self applyChatId:chatId kind:(PJQGKind)k setDefault:setDefault];
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

- (void)presentKindChooserForManualId:(NSString *)chatId {
    UIViewController *vc = [self topmost];
    if (!vc || vc.isBeingDismissed) { [self applyChatId:chatId kind:PJQGKindGroup setDefault:NO]; return; }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"归入哪个分组？"
                                message:chatId preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger k = PJQGKindGroup; k <= PJQGKindOther; k++) {
        [sheet addAction:[UIAlertAction actionWithTitle:PJQGKindName((PJQGKind)k)
                            style:UIAlertActionStyleDefault
                            handler:^(UIAlertAction *a) {
            [self applyChatId:chatId kind:(PJQGKind)k setDefault:NO];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                        style:UIAlertActionStyleCancel handler:nil]];
    [self anchorPopover:sheet];
    [vc presentViewController:sheet animated:YES completion:nil];
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

static void PJQGHookSetters(Class cls);

static BOOL PJQGIsChatVC(id vc) {
    if (!vc) return NO;
    NSString *n = NSStringFromClass([vc class]);
    if (n.length == 0) return NO;
    if ([n hasPrefix:@"PJQG"]) return NO;

    dispatch_once(&gPJQGOnce, ^{ gPJQGClassMatch = [NSMutableDictionary dictionary]; });
    NSNumber *cached = gPJQGClassMatch[n];
    if (cached) return cached.boolValue;

    BOOL ok = NO;
    NSString *reason = nil;
    @try {
        // 排除明显不是聊天窗口的
        BOOL excluded = [n containsString:@"MainFrame"] || [n containsString:@"NavigationController"] ||
                        [n containsString:@"TabBar"] || [n containsString:@"Window"] ||
                        [n containsString:@"Alert"] || [n containsString:@"Report"];
        if (!excluded) {
            if ([n containsString:@"MsgContent"] || [n containsString:@"ChatViewController"] ||
                [n containsString:@"ChatRoomViewController"] || [n containsString:@"SessionViewController"]) {
                ok = YES;
                reason = [NSString stringWithFormat:@"类名含特征词（%@）", n];
            } else if ([vc respondsToSelector:NSSelectorFromString(@"m_nsChatName")] ||
                       [vc respondsToSelector:NSSelectorFromString(@"m_nsChatRoomUserName")]) {
                ok = YES;
                reason = @"响应对应会话名选择子";
            }
        }
    } @catch (NSException *e) { ok = NO; }

    gPJQGClassMatch[n] = @(ok);
    if (ok) {
        gPJQGLasMatchReason = reason;
        PJQGLog(@"[匹配] 聊天窗口类 = %@   依据 = %@", n, reason ?: @"?");
    }
    return ok;
}

#pragma mark - Hook

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (PJQGIsChatVC(self)) {
        PJQGHookSetters([self class]);
        [[PJQGChatAction actionFor:(UIViewController *)self] install];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (PJQGIsChatVC(self)) {
        PJQGHookSetters([self class]);
        [[PJQGChatAction actionFor:(UIViewController *)self] install];
    }
}

%end

#pragma mark - 动态捕获 setter（MSHookMessageEx，取不到则降级）

typedef void (*PJQGMSHookMessageEx_t)(Class, SEL, IMP, IMP *);

static PJQGMSHookMessageEx_t gPJQGMSHook = NULL;
static BOOL                  gPJQGHookProbed = NO;
static NSMutableDictionary  *gPJQGHookTable = nil;   // "Cls|sel" -> NSNumber(uintptr_t) 原始 IMP

static BOOL PJQGClassHasOwnMethod(Class k, SEL s);

static IMP PJQGOrigIMPFor(id self, SEL _cmd) {
    if (!gPJQGHookTable) return NULL;
    NSString *sn = NSStringFromSelector(_cmd);
    Class k = object_getClass(self);
    int guard = 0;
    while (k && guard++ < 12) {
        NSString *key = [NSString stringWithFormat:@"%s|%@", class_getName(k), sn];
        NSNumber *v = gPJQGHookTable[key];
        if (v) return (IMP)(uintptr_t)v.unsignedLongLongValue;
        k = class_getSuperclass(k);
    }
    return NULL;
}

static void PJQGHookSetter(id self, SEL _cmd, id arg) {
    @try {
        NSString *cid = nil;
        NSString *src = nil;
        if ([arg isKindOfClass:NSString.class]) {
            cid = (NSString *)arg;
            src = NSStringFromSelector(_cmd);
        } else if (arg) {
            cid = PJQGUsrNameFromObject(arg);
            if (cid.length)
                src = [NSString stringWithFormat:@"%@ → m_nsUsrName", NSStringFromSelector(_cmd)];
        }
        if (cid.length > 0) PJQGRememberCapturedChatId(self, cid, src);
    } @catch (NSException *e) { }

    IMP orig = PJQGOrigIMPFor(self, _cmd);
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, arg);
}

static void PJQGHookSetters(Class cls) {
    if (!cls) return;
    if (!gPJQGHookProbed) {
        gPJQGHookProbed = YES;
        gPJQGMSHook = (PJQGMSHookMessageEx_t)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
        PJQGLog(@"[hook] MSHookMessageEx = %s", gPJQGMSHook ? "可用" : "不可用（动态捕获降级）");
    }
    if (!gPJQGMSHook) return;
    if (!gPJQGHookTable) gPJQGHookTable = [NSMutableDictionary dictionary];

    NSArray *sels = @[ @"setM_nsChatName:", @"setChatUserName:", @"setM_nsChatRoomUserName:",
                       @"setM_nsUsrName:", @"setM_nsRealChatUsr:", @"setM_oContact:",
                       @"setContact:", @"setM_contact:", @"setM_sessionInfo:",
                       @"setSessionInfo:", @"setM_oSessionInfo:" ];

    Class stopA = [UIViewController class];
    Class stopB = [UIResponder class];
    int guard = 0;
    for (Class k = cls; k && k != Nil && guard++ < 10; k = class_getSuperclass(k)) {
        if (k == stopA || k == stopB || k == [NSObject class]) break;
        for (NSString *sn in sels) {
            NSString *key = [NSString stringWithFormat:@"%s|%@", class_getName(k), sn];
            if (gPJQGHookTable[key]) continue;
            SEL s = NSSelectorFromString(sn);
            if (!PJQGClassHasOwnMethod(k, s)) continue;
            @try {
                IMP orig = NULL;
                gPJQGMSHook(k, s, (IMP)PJQGHookSetter, &orig);
                if (orig) {
                    gPJQGHookTable[key] = [NSNumber numberWithUnsignedLongLong:(unsigned long long)(uintptr_t)orig];
                    PJQGLog(@"[hook] 已捕获 %s %@", class_getName(k), sn);
                } else {
                    PJQGLog(@"[hook] %s %@ 原实现为空，跳过", class_getName(k), sn);
                }
            } @catch (NSException *e) {
                PJQGLog(@"[hook] %s %@ 失败: %@", class_getName(k), sn, e.reason);
            }
        }
    }
}

#pragma mark - 载入自证

// 启动后趁早把可能的聊天窗口类挂上 setter 捕获，提高「动态捕获」命中率
static void PJQGHookSettersEarly(void) {
    @try {
        NSMutableArray *targets = [NSMutableArray array];
        unsigned int count = 0;
        Class *all = objc_copyClassList(&count);
        if (all) {
            for (unsigned int i = 0; i < count; i++) {
                const char *nm = class_getName(all[i]);
                if (!nm) continue;
                NSString *s = [NSString stringWithUTF8String:nm];
                if ([s hasPrefix:@"PJQG"]) continue;
                if ([s containsString:@"MsgContent"] ||
                    [s containsString:@"ChatViewController"] ||
                    [s containsString:@"ChatRoomViewController"]) {
                    [targets addObject:s];
                    if (targets.count >= 60) break;
                }
            }
            free(all);
        }
        if (targets.count == 0) {
            PJQGLog(@"[hook] 早期候选类 0 个（聊天窗口类尚未注册，交由首次进入时挂钩）");
            return;
        }
        PJQGLog(@"[hook] 早期候选类 %lu 个: %@", (unsigned long)targets.count,
                [targets componentsJoinedByString:@", "]);
        for (NSString *cn in targets) {
            Class c = NSClassFromString(cn);
            if (c) PJQGHookSetters(c);
        }
    } @catch (NSException *e) {
        PJQGLog(@"[hook] 早期挂钩失败: %@", e.reason);
    }
}

static void PJQGShowLaunchAlert(void) {
    BOOL misaka = (NSClassFromString(@"PJGroupDataModel") || NSClassFromString(@"PJMisakaManager"));
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSString *risky = [ud objectForKey:kPJQGRiskyFlagKey];

    PJQGLog(@"[自检] MikotoHelper=%@ 默认=%ld 悬浮球=%@ 安全模式=%@ 深度诊断=%@",
            misaka ? @"✓" : @"✗", (long)PJQGDefaultKind(),
            PJQGBubbleVisible() ? @"显示" : @"隐藏",
            PJQGSafeMode() ? @"开" : @"关", PJQGDeepDiag() ? @"开" : @"关");

    NSString *title = [NSString stringWithFormat:@"MikotoQuickGroup v%@ 已加载 ✓", kPJQGVersion];
    NSString *msg;

    if (risky.length > 0) {
        [ud removeObjectForKey:kPJQGRiskyFlagKey];
        [ud synchronize];
        if ([risky isEqualToString:@"diag.ivar"]) {
            PJQGSetDeepDiag(NO);
            title = @"⚠️ 读取对象成员时崩溃过";
            msg = [NSString stringWithFormat:
                   @"上次崩溃发生在：%@\n\n已自动关闭「深度诊断」（不再读取对象成员变量），"
                    "功能不受影响。诊断报告里仍会列出成员变量的名称与类型。\n\n"
                    "崩溃日志：\n%@\n\n请把该文件发给我。", risky, PJQGLogPath()];
        } else {
            PJQGSetSafeMode(YES);
            title = @"⚠️ 上次运行发生过崩溃";
            msg = [NSString stringWithFormat:
                   @"上次崩溃发生在：\n%@\n\n"
                    "已自动进入安全模式（不会再调用该接口，所以不会再闪退）。\n\n"
                    "崩溃日志：\n%@\n\n请把该文件发给我。", risky, PJQGLogPath()];
        }
    } else if (!misaka) {
        msg = [NSString stringWithFormat:
               @"插件已加载，但没检测到 MikotoHelper 的分组模块。\n\n"
                "日志：%@", PJQGLogPath()];
    } else {
        msg = [NSString stringWithFormat:
               @"插件已被微信加载。\n\n"
                "进入任意聊天窗口：右侧有可拖动的「分组」按钮，旁边蓝色「诊」按钮直接打开诊断报告；"
                "右上角也有「分组」。\n\n"
                "单击「分组」= 归入默认分组；长按 = 菜单。\n\n"
                "若提示「未能识别当前会话」，会**自动弹出诊断报告**并复制到剪贴板，"
                "直接粘贴发给我即可。\n\n日志：%@", PJQGLogPath()];
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
    PJQGLog(@"MikotoQuickGroup v%@ 已注入 (pid=%d)", kPJQGVersion, getpid());
    PJQGLog(@"bundle = %@", NSBundle.mainBundle.bundleIdentifier ?: @"?");
    PJQGLog(@"MikotoHelper(Misaka) = %@",
            (NSClassFromString(@"PJGroupDataModel") || NSClassFromString(@"PJMisakaManager"))
                ? @"✓ 已检测到" : @"✗ 未检测到");
    PJQGLog(@"日志文件 = %@", PJQGLogPath());
    PJQGLog(@"================================================");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try { PJQGHookSettersEarly(); } @catch (NSException *e) { }
    });

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
            BOOL risky  = ([ud objectForKey:kPJQGRiskyFlagKey] != nil);
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
