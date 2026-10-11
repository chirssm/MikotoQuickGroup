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

static NSString *const kPJQGVersion          = @"1.7";
static NSString *const kPJQGDefaultKindKey   = @"pjqg_default_kind";   // NSInteger, -1 = 未设置
static NSString *const kPJQGBubbleVisibleKey = @"pjqg_bubble_visible";
static NSString *const kPJQGSilentKey        = @"pjqg_silent_alert";
static NSString *const kPJQGRiskyFlagKey     = @"pjqg_risky_open";     // 危险调用哨兵
static NSString *const kPJQGSafeModeKey      = @"pjqg_safe_mode";
static NSString *const kPJQGDeepDiagKey      = @"pjqg_deep_diag";      // 是否读取对象成员变量
// v1.6 新增：是否允许「碰微信全局单例」的深度识别（默认 NO）。
// v1.5 的教训：把 MMServiceCenter/MMSessionInfoManager 这类核心单例探测放进点击路径后，
// 点一下按钮就完全没反应（要么卡住主线程，要么拿到非对象返回值直接 SIGSEGV）。
static NSString *const kPJQGDeepIdentifyKey  = @"pjqg_deep_identify";

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
// v1.6：独立窗口 —— 点击后立刻可见的 HUD + 不依赖 present 的面板（报告页/对话框）
static void        PJQGHUD(NSString *text, BOOL sticky);
static void        PJQGHUDHide(void);
static void        PJQGShowPanel(UIViewController *vc);
static void        PJQGHidePanel(void);
static void        PJQGAlert(NSString *title, NSString *msg, NSString *copyText);
static UIViewController *PJQGAlertHost(void);
static void        PJQGPresentOnPanel(UIViewController *vc);
static BOOL        PJQGDeepIdentify(void);
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
static BOOL        PJQGPointerLooksSane(id o);
static NSArray    *PJQGIvarPatterns(void);
static BOOL        PJQGNameMatchesPatterns(NSString *low, NSArray *pats);
static NSString   *PJQGDiagnoseHead(id chatVC);
static NSArray    *PJQGIvarCandidateNames(id obj, NSUInteger max);
// v1.7：异常定位三件套 —— 阶段名 / 异常摘要（含调用栈）/ 内存日志尾部
static int          PJQGLooksLikeChatIdScore(NSString *s);
static NSString   *PJQGDumpException(NSException *e);
static NSString   *PJQGTailOfLog(NSUInteger maxLines);
static void         PJQGHookSettersGeneric(Class cls);
static void         PJQGCaptureStage(NSString *stage);

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

// ★ v1.7：阶段追踪。
//   教训：v1.4~v1.6 每次报错都只能拿到一句「Property Name should be baseRequest」，
//   根本不知道死在识别链、provider 查找、还是真正调用上。现在每一步都记阶段名，
//   异常逃出来时弹窗里会直接写「阶段：xxx」—— 一轮就能定位。
static NSString        *gPJQGStage = @"(未开始)";
static void PJQGCaptureStage(NSString *stage) { if (stage) gPJQGStage = stage; }
#define PJQGSTAGE(x) PJQGCaptureStage(x)

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

#pragma mark - v1.7 异常摘要（阶段 + 调用栈 + 日志尾部）

// 内存日志的末尾若干行 —— 异常弹窗里直接显示，省得去翻文件（也方便一次粘贴发回）
static NSString *PJQGTailOfLog(NSUInteger maxLines) {
    @try {
        NSString *all = gPJQGReport;
        if (all.length == 0) return @"(无日志)";
        NSArray *lines = [all componentsSeparatedByString:@"\n"];
        NSUInteger n = lines.count;
        NSUInteger start = (n > maxLines) ? (n - maxLines) : 0;
        NSMutableArray *keep = [NSMutableArray array];
        for (NSUInteger i = start; i < n; i++) {
            NSString *l = lines[i];
            if (l.length) [keep addObject:l];
        }
        return keep.count ? [keep componentsJoinedByString:@"\n"] : @"(无日志)";
    } @catch (NSException *e) { return @"(取日志失败)"; }
}

// 异常摘要：阶段名 + 异常名 + 原因 + 异常自己的调用栈 + 当前线程调用栈 + 最近日志
// 「调用栈」里会直接出现 微信/MikotoHelper 的方法名 —— 一眼就能看出是谁抛的。
static NSString *PJQGDumpException(NSException *e) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"==== MikotoQuickGroup 异常摘要 v%@ ====\n", kPJQGVersion];
    [s appendFormat:@"阶段    : %@\n", gPJQGStage ?: @"?"];
    [s appendFormat:@"异常名  : %@\n", e.name ?: @"?"];
    [s appendFormat:@"异常原因: %@\n", e.reason ?: @"?"];
    @try {
        NSArray *fr = e.callStackSymbols;
        if (fr.count) {
            [s appendString:@"--- 异常调用栈 ---\n"];
            NSUInteger lim = fr.count > 30 ? 30 : fr.count;
            for (NSUInteger i = 0; i < lim; i++) [s appendFormat:@"  %@\n", fr[i]];
        }
    } @catch (NSException *x) { }
    @try {
        NSArray *fr = NSThread.callStackSymbols;
        if (fr.count) {
            [s appendString:@"--- 当前线程调用栈 ---\n"];
            NSUInteger lim = fr.count > 30 ? 30 : fr.count;
            for (NSUInteger i = 0; i < lim; i++) [s appendFormat:@"  %@\n", fr[i]];
        }
    } @catch (NSException *x) { }
    [s appendString:@"--- 最近日志 ---\n"];
    [s appendString:PJQGTailOfLog(30)];
    return s;
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

// v1.6：默认关闭。打开后才会去碰微信的全局单例（MMServiceCenter 等）。
// 那是「最后手段」，代价是可能卡主线程甚至闪退，所以必须由用户显式开关。
static BOOL PJQGDeepIdentify(void) {
    NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:kPJQGDeepIdentifyKey];
    return n ? n.boolValue : NO;
}

static void PJQGSetDeepIdentify(BOOL v) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:v forKey:kPJQGDeepIdentifyKey];
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

#pragma mark - 独立窗口：HUD 与面板（v1.6 新增）

// ---------------------------------------------------------------------------
// 为什么要自己开 UIWindow？
// v1.4/v1.5 用的是 [某个 VC presentViewController:]。只要宿主 VC 不在窗口层级里、
// 或者正处在 transition / isBeingDismissed，UIKit 会「静默失败」——不抛异常、也没有
// 任何界面，表现就是「点了按钮完全没反应」。自己开一个 window 并把 VC 当作 root，
// 完全不经过 present 链，没有这种失败模式。
// ---------------------------------------------------------------------------

static UIWindow       *gPJQGHUDWindow    = nil;   // 只放 HUD，userInteractionEnabled=NO（点击穿透）
static UIWindow       *gPJQGPanelWindow  = nil;   // 报告页 / 对话框
static UIViewController *gPJQGPanelHome  = nil;   // 面板窗口的常驻空壳 root
static UILabel        *gPJQGHUDLabel     = nil;
static NSInteger       gPJQGHUDGen       = 0;

static UIWindow *PJQGHUDWindowRef(void) {
    if (gPJQGHUDWindow) return gPJQGHUDWindow;
    @try {
        UIWindow *w = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        w.windowLevel = UIWindowLevelAlert + 100;
        w.backgroundColor = [UIColor clearColor];
        w.userInteractionEnabled = NO;          // 关键：让触摸穿透过去，不影响微信
        w.rootViewController = [[UIViewController alloc] init];
        gPJQGHUDWindow = w;
    } @catch (NSException *e) { }
    return gPJQGHUDWindow;
}

// 屏幕下方的小提示条。sticky=YES 时不自动消失（用于「处理中…」这类需要被替换的提示）。
static void PJQGHUD(NSString *text, BOOL sticky) {
    NSString *t = [text copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *w = PJQGHUDWindowRef();
            if (!w) return;
            UILabel *l = gPJQGHUDLabel;
            if (!l) {
                l = [[UILabel alloc] init];
                l.numberOfLines = 0;
                l.textAlignment = NSTextAlignmentCenter;
                l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
                l.textColor = UIColor.whiteColor;
                l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.86];
                l.layer.cornerRadius = 10;
                l.clipsToBounds = YES;
                [w addSubview:l];
                gPJQGHUDLabel = l;
            }
            l.text = t;
            CGSize sz = [l sizeThatFits:CGSizeMake(w.bounds.size.width - 60, CGFLOAT_MAX)];
            l.frame = CGRectMake(0, 0, sz.width + 36, sz.height + 22);
            l.center = CGPointMake(w.bounds.size.width / 2, w.bounds.size.height * 0.72);
            l.hidden = NO;
            l.alpha = 1.0;
            w.hidden = NO;
            [w bringSubviewToFront:l];

            NSInteger myGen = ++gPJQGHUDGen;
            if (!sticky) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @try {
                        if (myGen != gPJQGHUDGen) return;      // 已被新的 HUD 取代
                        UILabel *cur = gPJQGHUDLabel;
                        if (!cur) return;
                        [UIView animateWithDuration:0.25 animations:^{ cur.alpha = 0.0; }
                                         completion:^(BOOL f) {
                            if (myGen != gPJQGHUDGen) return;
                            cur.hidden = YES;
                            gPJQGHUDWindow.hidden = YES;
                        }];
                    } @catch (NSException *e) { }
                });
            }
        } @catch (NSException *e) { }
    });
}

static void PJQGHUDHide(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            gPJQGHUDGen++;
            gPJQGHUDLabel.hidden = YES;
            gPJQGHUDWindow.hidden = YES;
        } @catch (NSException *e) { }
    });
}

static UIWindow *PJQGPanelWindowRef(void) {
    if (gPJQGPanelWindow) return gPJQGPanelWindow;
    @try {
        UIWindow *w = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        w.windowLevel = UIWindowLevelAlert + 50;      // 比 HUD 低
        w.backgroundColor = [UIColor clearColor];
        gPJQGPanelHome = [[UIViewController alloc] init];
        w.rootViewController = gPJQGPanelHome;
        gPJQGPanelWindow = w;
    } @catch (NSException *e) { }
    return gPJQGPanelWindow;
}

// 把任意 VC 直接当作面板窗口的 root 推上屏 —— 不走 present，永远不会被冲突吞掉
static void PJQGShowPanel(UIViewController *vc) {
    if (!vc) return;
    UIWindow *w = PJQGPanelWindowRef();
    if (!w) return;
    @try {
        PJQGHUDHide();                                  // 面板要上屏了，先把 HUD 收掉
        if (!gPJQGPanelHome) gPJQGPanelHome = [[UIViewController alloc] init];
        w.rootViewController = vc;
        w.hidden = NO;
        [w makeKeyAndVisible];
    } @catch (NSException *e) { }
}

static void PJQGHidePanel(void) {
    @try {
        UIWindow *w = gPJQGPanelWindow;
        if (!w) return;
        if (!gPJQGPanelHome) gPJQGPanelHome = [[UIViewController alloc] init];
        w.rootViewController = gPJQGPanelHome;
        w.hidden = YES;
    } @catch (NSException *e) { }
}

// 拿一个「一定在屏幕上、且当前没有别的弹窗」的宿主 VC，用来 present 对话框。
// 面板窗口的 root 满足这两个条件；它平时是空的、透明的。
static UIViewController *PJQGAlertHost(void) {
    @try {
        UIWindow *w = PJQGPanelWindowRef();
        if (w) {
            if (!w.rootViewController) {
                gPJQGPanelHome = [[UIViewController alloc] init];
                w.rootViewController = gPJQGPanelHome;
            }
            w.hidden = NO;
            [w makeKeyAndVisible];
            UIViewController *h = w.rootViewController;
            if (h && !h.presentedViewController) return h;
            if (h) {
                UIViewController *p = h.presentedViewController;
                int g = 0;
                while (p.presentedViewController && g++ < 6) p = p.presentedViewController;
                return p;
            }
        }
    } @catch (NSException *e) { }
    // 退路：原来的 keyWindow 方案
    for (UIWindow *win in UIApplication.sharedApplication.windows) {
        if (win.isKeyWindow) return win.rootViewController;
    }
    return nil;
}

// 弹窗消失后收起面板窗口（轮询实现，用普通 C 函数做递归，避免 block 自捕获的老坑）
static UIViewController *gPJQGWatchHost  = nil;
static int               gPJQGWatchTicks = 0;
static void PJQGPanelWatchTick(void);

static void PJQGPanelWatchStart(UIViewController *host) {
    gPJQGWatchHost = host;
    gPJQGWatchTicks = 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ @try { PJQGPanelWatchTick(); } @catch (NSException *e) { } });
}

static void PJQGPanelWatchTick(void) {
    UIViewController *h = gPJQGWatchHost;
    if (!h) return;
    if (!h.presentedViewController) {
        gPJQGWatchHost = nil;
        if (gPJQGPanelWindow && gPJQGPanelWindow.rootViewController == gPJQGPanelHome) {
            PJQGHidePanel();
        }
        return;
    }
    if (++gPJQGWatchTicks > 150) { gPJQGWatchHost = nil; return; }   // 最多等 ~60 秒
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ @try { PJQGPanelWatchTick(); } @catch (NSException *e) { } });
}

// 面板窗口上弹对话框，并在它消失后自动把面板窗口收起来（否则那层空窗口会挡住微信的点击）
static void PJQGPresentOnPanel(UIViewController *vc) {
    if (!vc) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIViewController *host = PJQGAlertHost();
            if (!host) return;
            if (host.presentedViewController) return;      // 已经有弹窗了，不叠
            [host presentViewController:vc animated:YES completion:nil];
            PJQGPanelWatchStart(host);
        } @catch (NSException *e) { }
    });
}

// 最后的兜底：只要还能建 UIWindow，就一定有界面。
// copyText 非空时给一个「复制全文」按钮，方便直接把诊断信息发回。
static void PJQGAlert(NSString *title, NSString *msg, NSString *copyText) {
    NSString *t = [title copy];
    NSString *m = [msg copy];
    NSString *c = [copyText copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIViewController *host = PJQGAlertHost();
            if (!host) return;
            if (host.presentedViewController) return;
            UIAlertController *al = [UIAlertController alertControllerWithTitle:t
                                    message:m preferredStyle:UIAlertControllerStyleAlert];
            if (c.length) {
                [al addAction:[UIAlertAction actionWithTitle:@"复制全文"
                                    style:UIAlertActionStyleDefault
                                    handler:^(UIAlertAction *a) {
                    @try { UIPasteboard.generalPasteboard.string = c; } @catch (NSException *e) { }
                }]];
            }
            [al addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel
                                handler:nil]];
            [host presentViewController:al animated:YES completion:nil];
            PJQGPanelWatchStart(host);
        } @catch (NSException *e) { }
    });
}

#pragma mark - 运行时反射

static BOOL PJQGIsClassObjectSafely(id o) {
    if (!o) return NO;
    @try { return class_isMetaClass(object_getClass(o)); } @catch (NSException *e) { return NO; }
}

// 从 ivar 里读出来的指针做一次廉价合理性检查，尽量避免拿野指针去调 isKindOfClass:（那是 SIGSEGV，@try 拦不住）
static BOOL PJQGPointerLooksSane(id o) {
    uintptr_t p = (uintptr_t)o;
    if (p == 0) return NO;
    if ((p & 0x8000000000000000ULL) != 0) return YES;   // objc tagged pointer，运行时自己会处理
    if ((p & 0x7ULL) != 0) return NO;                   // 未对齐 → 基本可断定不是对象指针
    if (p < 0x10000000ULL) return NO;                   // 明显不是堆/数据段指针
    return YES;
}

// 只按「名字」筛出可能与会话/联系人相关的对象成员（不读内存，绝不抛异常）
static NSArray *PJQGIvarCandidateNames(id obj, NSUInteger max) {
    NSMutableArray *out = [NSMutableArray array];
    if (!obj) return out;
    @try {
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
                if (!name) continue;
                NSString *low = name.lowercaseString;
                if (!PJQGNameMatchesPatterns(low, PJQGIvarPatterns()) &&
                    ![low containsString:@"delegate"] &&
                    ![low containsString:@"logic"]) continue;
                [out addObject:name];
                if (out.count >= max) { free(ivs); return out; }
            }
            free(ivs);
        }
    } @catch (NSException *e) { }
    return out;
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
    return @[ @"m_delegate", @"delegate", @"m_oDelegate", @"m_logicDelegate",
              @"m_logicController", @"logicController", @"m_oLogicController",
              @"logicCtrl", @"m_logicCtrl", @"viewLogicController",
              @"m_oViewLogicController", @"logic", @"m_logic",
              @"m_chatLogicController", @"chatController", @"m_controller",
              @"m_msgLogicController", @"m_oMsgLogicController", @"m_msgLogicManager",
              @"m_oContact", @"m_ovChatContact", @"contact", @"m_contact",
              @"m_oSessionInfo", @"sessionInfo", @"m_sessionInfo",
              @"m_oSession", @"session", @"m_oChatViewModel", @"m_oLogicHelper" ];
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
            id v = object_getIvar(obj, iv);
            if (v && !PJQGPointerLooksSane(v)) return nil;   // 野指针直接丢弃
            return v;
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
                if (!PJQGPointerLooksSane(v)) continue;
                if (![v isKindOfClass:NSString.class]) continue;
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

#pragma mark - ⑦ 全局服务链 / ⑧ 消息回溯

// 只在「类方法」里找单例访问器。
// ★ v1.6 关键加固：调用前必须确认该方法的「返回类型是对象 且 没有额外参数」。
//   v1.5 没做这一步，直接 objc_msgSend 拿返回值当 id 用：如果那个 +shared/+instance
//   其实返回 BOOL/int，返回的就是个 0/1 之类的非指针，随后 isKindOfClass: 解引用
//   非法地址 → SIGSEGV，@try 完全拦不住 → 微信直接挂掉 / 表现为「点了没反应」。
static id PJQGSingletonForClass(Class c) {
    if (!c) return nil;
    for (NSString *g in @[ @"defaultCenter", @"sharedInstance", @"sharedManager",
                           @"defaultManager", @"shared", @"instance",
                           @"defaultInstance", @"getInstance", @"sharedModel" ]) {
        SEL s = NSSelectorFromString(g);
        if (!s) continue;
        Method m = class_getClassMethod(c, s);
        if (!m) continue;

        // 返回类型必须恰好是对象
        char rt[16] = {0};
        method_getReturnType(m, rt, sizeof(rt));
        if (rt[0] != '@') continue;
        // 只能是无参方法（class 方法本身占 self/_cmd 两个位置参数）
        if (method_getNumberOfArguments(m) != 2) continue;

        @try {
            id v = ((id (*)(id, SEL))objc_msgSend)((id)c, s);
            if (!v) continue;
            if (!PJQGPointerLooksSane(v)) continue;
            if (PJQGIsClassObjectSafely(v)) continue;      // 拿到的是类对象，不要
            if ([v isKindOfClass:NSObject.class]) return v;
        } @catch (NSException *e) { } @catch (...) { }
    }
    return nil;
}

// 在一个「管理器 / 会话对象」上找会话 ID：先看自己的字符串成员，再钻名字像 session/current 的对象成员
static NSString *PJQGChatIdFromServiceObject(id svc, NSString **how, NSMutableString *trace, NSString *tag) {
    if (!svc) return nil;

    for (NSString *k in PJQGChatIdKeyCandidates()) {
        NSString *v = PJQGSafeStringForKey(svc, k, NULL);
        if (v && PJQGLooksLikeChatIdScore(v) >= 15) {
            if (how) *how = [NSString stringWithFormat:@"%@.%@", tag, k];
            if (trace) [trace appendFormat:@"  ⑦ %@.%@ = %@  ✓\n", tag, k, v];
            return v;
        }
    }

    @try {
        int guard = 0;
        for (Class k = [svc class]; k && k != Nil && guard++ < 12; k = class_getSuperclass(k)) {
            unsigned int cnt = 0;
            Ivar *ivs = class_copyIvarList(k, &cnt);
            if (!ivs) continue;
            for (unsigned int i = 0; i < cnt; i++) {
                const char *nm = ivar_getName(ivs[i]);
                const char *tt = ivar_getTypeEncoding(ivs[i]);
                if (!nm || !tt || tt[0] != '@') continue;
                NSString *name = [NSString stringWithUTF8String:nm];
                NSString *low  = name.lowercaseString;
                if (!([low containsString:@"session"] || [low containsString:@"current"] ||
                      [low containsString:@"last"]    || [low containsString:@"chat"] ||
                      [low containsString:@"conversation"])) continue;

                id v = nil;
                @try { v = object_getIvar(svc, ivs[i]); } @catch (NSException *e) { continue; }
                if (!PJQGPointerLooksSane(v)) continue;
                if (PJQGIsClassObjectSafely(v)) continue;

                NSString *r = PJQGUsrNameFromObject(v);
                if (r && PJQGLooksLikeChatIdScore(r) >= 15) {
                    if (how) *how = [NSString stringWithFormat:@"%@.%@→%@", tag, name, NSStringFromClass([v class])];
                    if (trace) [trace appendFormat:@"  ⑦ %@.%@(→%@) = %@  ✓\n",
                                tag, name, NSStringFromClass([v class]), r];
                    return r;
                }
                NSString *r2 = PJQGChatIdFromIvars(v, NULL);
                if (r2) {
                    if (how) *how = [NSString stringWithFormat:@"%@.%@.ivar", tag, name];
                    if (trace) [trace appendFormat:@"  ⑦ %@.%@(→%@) ivar = %@  ✓\n",
                                tag, name, NSStringFromClass([v class]), r2];
                    return r2;
                }
            }
            free(ivs);
        }
    } @catch (NSException *e) { }
    return nil;
}

static NSString *PJQGChatIdFromGlobalServices(NSString **how, NSMutableString *trace) {
    NSArray *svcNames = @[ @"MMSessionInfoManager", @"MMMsgLogicManager", @"MMChatSessionManager",
                           @"MMSessionRing", @"MMLogicMgr", @"MMUIManager", @"CUtility" ];
    @try {
        for (NSString *cn in svcNames) {
            Class c = NSClassFromString(cn);
            if (!c) continue;
            id svc = PJQGSingletonForClass(c);
            if (!svc) continue;
            NSString *v = PJQGChatIdFromServiceObject(svc, how, trace, cn);
            if (v) return v;
        }

        Class msc = NSClassFromString(@"MMServiceCenter");
        if (msc) {
            id center = PJQGSingletonForClass(msc);
            SEL gs = NSSelectorFromString(@"getService:");
            if (center && class_getInstanceMethod([center class], gs)) {
                for (NSString *cn in svcNames) {
                    Class sc = NSClassFromString(cn);
                    if (!sc) continue;
                    @try {
                        id svc = ((id (*)(id, SEL, id))objc_msgSend)(center, gs, (id)sc);
                        if (!svc || PJQGIsClassObjectSafely(svc)) continue;
                        NSString *v = PJQGChatIdFromServiceObject(
                            svc, how, trace, [NSString stringWithFormat:@"ServiceCenter/%@", cn]);
                        if (v) return v;
                    } @catch (NSException *e) { }
                }
            }
        }
    } @catch (NSException *e) {
        if (trace) [trace appendFormat:@"  ⑦ 异常: %@\n", e.reason];
    }
    return nil;
}

// 从一个「消息对象」里安全地取出会话 ID。
// 规则（很重要，否则会把「我自己」当成会话）：
//   · m_nsRealChatUsr 是微信专门保存的「真实会话用户名」，与消息方向无关 → 直接采用
//   · m_nsFromUsr / m_nsToUsr 在不同方向下会互换（单聊里 m_nsToUsr 甚至等于我自己的号），
//     所以只有当值本身带 @chatroom / @openim 这种「无歧义」特征时才接受
static NSString *PJQGChatIdFromMessageObject(id msg, NSString **how, NSMutableString *trace, NSString *tag) {
    if (!msg || !PJQGPointerLooksSane(msg) || PJQGIsClassObjectSafely(msg)) return nil;
    @try {
        NSString *real = PJQGSafeStringForKey(msg, @"m_nsRealChatUsr", NULL);
        if (real.length && PJQGLooksLikeChatIdScore(real) >= 15) {
            if (how) *how = [NSString stringWithFormat:@"%@.m_nsRealChatUsr", tag];
            if (trace) [trace appendFormat:@"  %@.m_nsRealChatUsr = %@  ✓\n", tag, real];
            return real;
        }
        for (NSString *f in @[ @"m_nsFromUsr", @"m_nsToUsr", @"m_nsChatName",
                               @"m_nsChatRoomUserName", @"m_nsUsrName" ]) {
            NSString *v = PJQGSafeStringForKey(msg, f, NULL);
            if (!v) continue;
            if (!([v containsString:@"@chatroom"] || [v containsString:@"@openim"])) continue;
            if (how) *how = [NSString stringWithFormat:@"%@.%@", tag, f];
            if (trace) [trace appendFormat:@"  %@.%@ = %@  ✓\n", tag, f, v];
            return v;
        }
    } @catch (NSException *e) { }
    return nil;
}

// ④·5 聊天窗口自己持有的「单条消息对象」（报告里能看到 m_lastMsgInNewArray / m_firstUnReadMsg
//      / m_scrollTargetMsg 等，类型都是 CMessageWrap）—— 会话里必然有消息，命中率高且完全安全
static NSString *PJQGChatIdFromSingleMsgIvars(id vc, NSString **how, NSMutableString *trace) {
    static NSArray *keys = nil;
    if (!keys) keys = @[ @"m_lastMsgInNewArray", @"m_firstUnReadMsg", @"m_scrollTargetMsg",
                         @"m_currentSpeakTextMsg", @"m_referOwnerMsg", @"m_referKeeperMsg",
                         @"m_lastScrollingHandledMessage" ];
    @try {
        for (NSString *k in keys) {
            id msg = PJQGSafeObjectForKey(vc, k);
            if (!msg) continue;
            NSString *v = PJQGChatIdFromMessageObject(msg, how, trace, k);
            if (v) return v;
        }
    } @catch (NSException *e) { }
    return nil;
}

// ⑧ 从当前会话的消息数组反推
static NSString *PJQGChatIdFromMessages(id vc, NSString **how, NSMutableString *trace) {
    @try {
        for (NSString *arrKey in @[ @"m_arrMessageNodeData", @"m_newArrMessageNodeData",
                                    @"m_arrMsgData", @"m_arrMessages" ]) {
            id arr = PJQGSafeObjectForKey(vc, arrKey);
            if (!arr || PJQGIsClassObjectSafely(arr)) continue;
            if (![arr isKindOfClass:NSArray.class]) continue;
            NSArray *a = (NSArray *)arr;
            if (a.count == 0) continue;

            NSInteger lo = (NSInteger)a.count - 12;
            if (lo < 0) lo = 0;
            for (NSInteger idx = (NSInteger)a.count - 1; idx >= lo; idx--) {
                id msg = a[(NSUInteger)idx];
                NSString *tag = [NSString stringWithFormat:@"%@[%ld]", arrKey, (long)idx];
                NSString *v = PJQGChatIdFromMessageObject(msg, how, trace, tag);
                if (v) return v;
            }
        }
    } @catch (NSException *e) { }
    return nil;
}

static NSString *PJQGChatIdInner(id vc, NSString **how, NSMutableString *trace) {
    if (how) *how = nil;
    if (!vc) return nil;
    NSArray *kvcKeys = PJQGChatIdKeyCandidates();
    NSArray *selNames = PJQGChatIdSelCandidates();

    // ① 动态捕获
    PJQGSTAGE(@"识别①动态捕获");
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
    PJQGSTAGE(@"识别②KVC");
    for (NSString *k in kvcKeys) {
        NSString *v = PJQGSafeStringForKey(vc, k, NULL);
        if (trace) [trace appendFormat:@"  ② KVC %@ = %@\n", k, v ?: @"(无)"];
        if (v) { if (how) *how = [NSString stringWithFormat:@"KVC %@", k]; return v; }
    }

    // ③ 选择子探测
    PJQGSTAGE(@"识别③选择子探测");
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
    PJQGSTAGE(@"识别④成员变量扫描");
    NSString *ivHow = nil;
    NSString *iv = PJQGChatIdFromIvars(vc, &ivHow);
    if (trace) [trace appendFormat:@"  ④ 成员变量扫描 = %@\n",
                iv ? [NSString stringWithFormat:@"\"%@\" (%@)", iv, ivHow] : @"(无)"];
    if (iv) { if (how) *how = [NSString stringWithFormat:@"成员变量 %@", ivHow]; return iv; }

    // ④·5 聊天窗口自己持有的「单条消息对象」（m_lastMsgInNewArray / m_firstUnReadMsg …）
    PJQGSTAGE(@"识别④·5单条消息对象");
    //      这些 ivar 的类型就是 CMessageWrap，会话里一定有消息，命中率很高。
    {
        NSString *how45 = nil;
        NSString *v45 = PJQGChatIdFromSingleMsgIvars(vc, &how45, trace);
        if (v45) { if (how) *how = how45 ?: @"单条消息对象"; return v45; }
        if (trace) [trace appendString:@"  ④·5 单条消息对象 = (无)\n"];
    }

    // ⑤ 子对象链（逻辑控制器 / 联系人 / 会话对象）
    PJQGSTAGE(@"识别⑤子对象链");
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

    // ⑦ 微信全局服务链（会话管理器 / MMServiceCenter 中转）
    // ★ v1.6：默认关闭。
    // v1.5 把它放进了「点击路径」，结果点一下按钮完全没有反应 —— 这段会去调微信的
    // 核心单例（MMSessionInfoManager / MMMsgLogicManager / MMServiceCenter getService:），
    // 在主线程上做重型初始化，轻则卡住好几秒，重则拿到非对象返回值直接 SIGSEGV。
    // 现在必须用户在长按菜单里显式打开「深度识别」才会走这一段。
    if (PJQGDeepIdentify()) {
        PJQGSTAGE(@"识别⑦全局服务链");
        NSString *how7 = nil;
        NSString *v7 = PJQGChatIdFromGlobalServices(&how7, trace);
        if (v7) { if (how) *how = how7 ?: @"全局服务链"; return v7; }
        if (trace) [trace appendString:@"  ⑦ 全局服务链 = (无)\n"];
    } else if (trace) {
        [trace appendString:@"  ⑦ 全局服务链 = (已跳过：深度识别关闭，默认不走微信核心单例)\n"];
    }

    // ⑧ 消息回溯（消息对象里的收发方用户名就是最原始的会话 ID）
    PJQGSTAGE(@"识别⑧消息回溯");
    {
        NSString *how8 = nil;
        NSString *v8 = PJQGChatIdFromMessages(vc, &how8, trace);
        if (v8) { if (how) *how = how8 ?: @"消息回溯"; return v8; }
        if (trace) [trace appendString:@"  ⑧ 消息回溯 = (无)\n"];
    }

    // ⑨ 全局兜底 —— 只提示不自动使用（避免分错会话）
    if (trace) {
        if (gPJQGLastCapturedId.length)
            [trace appendFormat:@"  ⑨ 全局捕获过 = %@ (%@)  ← 仅提示，不自动使用\n",
                gPJQGLastCapturedId, gPJQGLastCapturedHow ?: @"?"];
        else
            [trace appendString:@"  ⑨ 全局捕获 = (无)\n"];
    }
    return nil;
}

// ★ v1.7：识别链整体再包一层。
//   即使将来某个微信版本里又出现「没被 @try 覆盖到」的调用，也只会「识别失败/退回报告」，
//   不会再把异常抛给上层变成「分组出现异常」弹窗。trace 里会写清死在哪个阶段。
static NSString *PJQGChatIdEx(id vc, NSString **how, NSMutableString *trace) {
    @try {
        return PJQGChatIdInner(vc, how, trace);
    } @catch (NSException *e) {
        PJQGLog(@"[识别] 异常 @阶段[%@]: %@", gPJQGStage, e.reason);
        if (trace) [trace appendFormat:@"  ⚠︎ 识别链异常 @%@ : %@\n", gPJQGStage, e.reason];
        if (how) *how = [NSString stringWithFormat:@"异常(%@)", gPJQGStage];
        return nil;
    } @catch (...) {
        if (trace) [trace appendString:@"  ⚠︎ 识别链非 ObjC 异常\n"];
        return nil;
    }
}

static NSString *PJQGChatId(id vc, NSString **how) {
    return PJQGChatIdEx(vc, how, nil);
}

#pragma mark - provider 查找（只走"类 / 单例"路径，不做对象图遍历）

static NSMutableDictionary *gPJQGProviderCache = nil;

static id PJQGFindProviderInner(SEL sel, NSString **howFound) {
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
        if (![cn hasPrefix:@"PJ"] && ![cn hasPrefix:@"Misaka"] && ![cn hasPrefix:@"Mikoto"]) continue;
        Class c = NSClassFromString(cn);
        if (!c) continue;

        if (class_getClassMethod(c, sel)) {
            if (howFound) *howFound = [NSString stringWithFormat:@"类方法 +[%@ %@]", cn, key];
            gPJQGProviderCache[key] = (id)c;
            return (id)c;
        }

        // 注意：respondsToSelector: 会触发该类的 +initialize，而 +initialize 里可能抛异常
        // （MikotoHelper 的类会去碰微信的 protobuf 对象）。整个探测循环必须包 @try。
        // ★ v1.6：改成「先查 Method 的返回类型/参数个数，再决定要不要发消息」。
        //   顺便不再用 respondsToSelector:（它会触发 +initialize），改用 class_getInstanceMethod。
        @try {
            for (NSString *g in @[ @"sharedInstance", @"sharedManager", @"defaultManager", @"shared",
                                   @"manager", @"defaultInstance", @"instance", @"getInstance",
                                   @"sharedModel", @"sharedDataModel", @"currentManager" ]) {
                SEL gs = NSSelectorFromString(g);
                if (!gs) continue;
                Method gm = class_getClassMethod(c, gs);
                if (!gm) continue;
                char grt[16] = {0};
                method_getReturnType(gm, grt, sizeof(grt));
                if (grt[0] != '@') continue;                 // 返回值不是对象 → 绝不能当 id 用
                if (method_getNumberOfArguments(gm) != 2) continue;

                id inst = ((id (*)(id, SEL))objc_msgSend)((id)c, gs);
                if (!inst) continue;
                if (!PJQGPointerLooksSane(inst)) continue;
                if (PJQGIsClassObjectSafely(inst)) continue;
                Method im = class_getInstanceMethod([inst class], sel);
                if (!im) continue;
                char irt[16] = {0};
                method_getReturnType(im, irt, sizeof(irt));
                // 目标方法可以没有返回值（addGroupData: 之类常见是 void），所以这里不做限制
                (void)irt;
                if (howFound) *howFound = [NSString stringWithFormat:@"单例 +[%@ %@]", cn, g];
                gPJQGProviderCache[key] = inst;
                return inst;
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

// ★ v1.7：provider 查找整段兜底。
//   provider 探测要往「实现了 addGroupData: 的类的单例访问器」发消息，那会触发对方 +initialize，
//   而 +initialize 里可能直接抛异常（v1.4 报告里的 baseResponse、v1.6 的 baseRequest 都属于这一类）。
//   内部本来就有 @try，这里再包一层，确保它永远不会把异常抛给调用者。
static id PJQGFindProvider(SEL sel, NSString **howFound) {
    @try {
        return PJQGFindProviderInner(sel, howFound);
    } @catch (NSException *e) {
        PJQGLog(@"[provider] 异常 @阶段[%@]: %@", gPJQGStage, e.reason);
        if (howFound) *howFound = [NSString stringWithFormat:@"异常(%@)", e.reason ?: @"?"];
        return nil;
    } @catch (...) {
        if (howFound) *howFound = @"非 ObjC 异常";
        return nil;
    }
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

static PJQGApplyResult PJQGApplyInner(NSString *chatId, PJQGKind kind, NSString **detail) {
    if (detail) *detail = nil;
    if (chatId.length == 0) { if (detail) *detail = @"会话 ID 为空"; return PJQGApplyNoProvider; }
    if (PJQGSafeMode()) return PJQGApplySafeMode;

    NSString *selName = PJQGSelectorForKind(kind);
    if (selName.length == 0) { if (detail) *detail = @"分组类型非法"; return PJQGApplyNoProvider; }
    SEL add = NSSelectorFromString(selName);
    if (!add) { if (detail) *detail = @"选择子构造失败"; return PJQGApplyNoProvider; }
    PJQGLog(@"[apply] 目标选择子 = %@  会话ID = %@", selName, chatId);

    PJQGSTAGE(@"apply:查找写入接口");
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
    PJQGSTAGE(@"apply:调用写入接口");
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

    PJQGSTAGE(@"apply:刷新会话列表");
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

// ★ v1.7：整个写入流程最外层兜底 —— 任何异常转成「调用报错：xxx（阶段 yyy）」，
//   走正常的失败提示 + 报告，而不是弹「分组出现异常」。
static PJQGApplyResult PJQGApply(NSString *chatId, PJQGKind kind, NSString **detail) {
    @try {
        return PJQGApplyInner(chatId, kind, detail);
    } @catch (NSException *e) {
        PJQGLog(@"[apply] ✗ 异常逃出 @阶段[%@]: %@", gPJQGStage, e.reason);
        if (detail) *detail = [NSString stringWithFormat:@"%@（阶段 %@）", e.reason ?: e.name ?: @"?", gPJQGStage];
        return PJQGApplyException;
    } @catch (...) {
        if (detail) *detail = [NSString stringWithFormat:@"非 ObjC 异常（阶段 %@）", gPJQGStage];
        return PJQGApplyException;
    }
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

    // ★ 当前聊天窗口放在最前面：这是最关键的一段，后面任何一块炸了都不影响它
    @try {
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
    } @catch (NSException *e) {
        [s appendFormat:@"  ⚠︎ 当前聊天窗口段异常: %@\n", e.reason];
    }

    @try {
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
    } @catch (NSException *e) {
        [s appendFormat:@"⚠︎ 类/方法探测段异常: %@\n", e.reason];
    }

    // provider 解析会去调未知类的单例访问器（可能触发 +initialize 抛异常），单独 @try
    @try {
        [s appendString:@"\n--- provider 解析 ---\n"];
        for (NSString *sn in @[ @"addGroupData:", @"addChatData:", @"addOtherGroupData:", @"rebuildMainSessions" ]) {
            NSString *how = nil;
            id p = PJQGFindProvider(NSSelectorFromString(sn), &how);
            [s appendFormat:@"  %@\n      %@  via %@\n", sn,
                p ? NSStringFromClass([p class]) : @"(未找到)", how ?: @"-"];
        }
    } @catch (NSException *e) {
        [s appendFormat:@"⚠︎ provider 解析段异常: %@\n", e.reason];
    }

    @try {
        [s appendString:@"\n--- PJ* 类清单 ---\n"];
        NSArray *pj = PJQGClassNamesWithPrefix(@"PJ");
        [s appendFormat:@"  PJ* 共 %lu 个\n", (unsigned long)pj.count];
        for (NSString *prefix in @[ @"PJGroup", @"PJMisaka", @"PJTag", @"PJHelper", @"PJUtils", @"PJSetting" ]) {
            NSMutableArray *hit = [NSMutableArray array];
            for (NSString *n in pj) if ([n hasPrefix:prefix]) [hit addObject:n];
            if (hit.count) [s appendFormat:@"  %@: %@\n", prefix, [hit componentsJoinedByString:@", "]];
        }
    } @catch (NSException *e) { }

    [s appendString:@"\n--- NSUserDefaults 相关键 ---\n"];
    int shown = 0;
    NSDictionary *d = nil;
    @try { d = ud.dictionaryRepresentation; } @catch (NSException *e) { }
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

// ---------------- ★ 关键结论（短版，专为「整段粘贴发回」设计） ----------------
// 之前你贴回来的报告被聊天输入框截断了（142 条成员变量只到第 ~110 条）。
// 这一段把「我下一步做判断所必需的信息」压到几十行，永远不会被截断。
// 全部只走运行时元数据 + 受控取值，每块独立 @try，任何一块炸了都不影响其它块。
static NSString *PJQGDiagnoseHead(id chatVC) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"##### 关键结论 v%@ #####\n", kPJQGVersion];

    // 1) 窗口
    @try {
        [s appendFormat:@"窗口类   : %@\n", chatVC ? NSStringFromClass([chatVC class]) : @"(无)"];
        [s appendFormat:@"匹配原因 : %@\n", gPJQGLasMatchReason ?: @"?"];
        [s appendFormat:@"动态捕获 : %@ (%@)\n",
            objc_getAssociatedObject(chatVC, kPJQGCapturedIdKey) ?: @"(无)",
            objc_getAssociatedObject(chatVC, kPJQGCapturedHowKey) ?: @"-"];
    } @catch (NSException *e) { }

    // 2) 识别结果 + 完整识别链（哪一级命中/失败）
    @try {
        if (chatVC) {
            NSMutableString *tr = [NSMutableString string];
            NSString *how = nil;
            NSString *cid = PJQGChatIdEx(chatVC, &how, tr);
            [s appendFormat:@"识别结果 : %@   (来源 %@)\n", cid ?: @"(未取到)", how ?: @"-"];
            [s appendString:@"识别链   :\n"];
            [s appendString:tr];
        } else {
            [s appendString:@"识别结果 : (无聊天窗口)\n"];
        }
    } @catch (NSException *e) {
        [s appendFormat:@"识别链   : ⚠︎ 异常 %@\n", e.reason];
    }

    // 3) MikotoHelper 是否已加载
    @try {
        [s appendString:@"Mikoto类 :"];
        for (NSString *cn in @[ @"PJGroupDataModel", @"PJMisakaManager", @"PJGroupManager",
                                @"PJManagerModel", @"PJHelper", @"PJMisakaSettingViewController" ]) {
            [s appendFormat:@" %@=%@", cn, NSClassFromString(cn) ? @"✓" : @"✗"];
        }
        [s appendString:@"\n"];
    } @catch (NSException *e) { }

    // 4) 写入接口（provider 解析结果）
    @try {
        for (NSString *sn in @[ @"addGroupData:", @"addChatData:", @"addOtherGroupData:",
                                @"rebuildMainSessions" ]) {
            NSString *how = nil;
            id p = PJQGFindProvider(NSSelectorFromString(sn), &how);
            [s appendFormat:@"写入接口 : %@ → %@ (%@)\n", sn,
                p ? NSStringFromClass([p class]) : @"(未找到)", how ?: @"-"];
        }
    } @catch (NSException *e) {
        [s appendFormat:@"写入接口 : ⚠︎ 异常 %@\n", e.reason];
    }

    // 5) 会话 ID 候选字段（只看名字，不读内存）
    @try {
        NSArray *names = PJQGIvarCandidateNames(chatVC, 40);
        [s appendFormat:@"候选字段 : %@\n",
            names.count ? [names componentsJoinedByString:@", "] : @"(无)"];
    } @catch (NSException *e) { }

    // 6) 关键取值（只读候选里的对象成员，带野指针检查）
    @try {
        if (!PJQGDeepDiag()) {
            [s appendString:@"关键取值 : (深度诊断关闭，未读取)\n"];
        } else if (chatVC) {
            NSArray *names = PJQGIvarCandidateNames(chatVC, 40);
            NSMutableArray *lines = [NSMutableArray array];
            for (NSString *n in names) {
                if (lines.count >= 14) break;
                id v = PJQGSafeObjectForKey(chatVC, n);
                if (!v || ![v isKindOfClass:NSObject.class]) continue;
                if ([v isKindOfClass:NSString.class]) {
                    NSString *sv = (NSString *)v;
                    if (sv.length == 0 || sv.length > 80) continue;
                    [lines addObject:[NSString stringWithFormat:@"  %@ = \"%@\"", n, sv]];
                } else {
                    [lines addObject:[NSString stringWithFormat:@"  %@ : %@", n, NSStringFromClass([v class])]];
                }
            }
            [s appendString:@"关键取值 :\n"];
            [s appendString:lines.count ? [lines componentsJoinedByString:@"\n"] : @"  (无)"];
            [s appendString:@"\n"];
        }
    } @catch (NSException *e) {
        [s appendFormat:@"关键取值 : ⚠︎ 异常 %@\n", e.reason];
    }

    [s appendString:@"##### 以上整段复制发回即可 #####\n"];
    return s;
}

// 自动复制时只复制「关键结论」段，避免再次被聊天输入框截断
static NSString *PJQGHeadOnly(NSString *full) {
    if (full.length == 0) return @"";
    NSRange r = [full rangeOfString:@"\n\n########## 最小报告"];
    if (r.location != NSNotFound) return [full substringToIndex:r.location];
    return full;
}

static NSString *PJQGDiagnose(id chatVC) {
    NSMutableString *out = [NSMutableString string];

    // 第一段：关键结论（短）
    @try { [out appendString:PJQGDiagnoseHead(chatVC)]; }
    @catch (NSException *e) { [out appendFormat:@"(关键结论段失败: %@)\n", e.reason]; }

    // 第二段：最小报告（纯元数据，含成员变量全表）
    @try {
        [out appendString:@"\n\n########## 最小报告（元数据） ##########\n"];
        [out appendString:PJQGDiagnoseMini(chatVC)];
    } @catch (NSException *e) { [out appendFormat:@"(最小报告失败: %@)\n", e.reason]; }

    // 第三段：完整报告（尽力输出）
    @try {
        [out appendString:@"\n\n########## 完整报告（尽力输出） ##########\n"];
        [out appendString:PJQGDiagnoseDetail(chatVC)];
    } @catch (NSException *e) {
        [out appendFormat:@"⚠︎ 完整报告在此处中断: %@\n", e.reason ?: e.name];
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
- (void)onCopyHead;
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
    [btns addObject:[self makeButton:@"复制结论" action:@selector(onCopyHead)]];
    [btns addObject:[self makeButton:@"复制全文" action:@selector(onCopy)]];
    [btns addObject:[self makeButton:@"分享"     action:@selector(onShare)]];
    if (self.onManualInput) {
        [btns addObject:[self makeButton:@"输入ID" action:@selector(onManual)]];
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
    b.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
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
            UIPasteboard.generalPasteboard.string = PJQGHeadOnly(self.reportText ?: @"");
            [self localToast:@"已自动复制「关键结论」，直接粘贴发回即可"];
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

- (void)onCopyHead {
    @try {
        UIPasteboard.generalPasteboard.string = PJQGHeadOnly(self.reportText ?: @"");
        [self localToast:@"已复制「关键结论」，直接粘贴发回即可"];
    } @catch (NSException *e) { }
}

- (void)onCopy {
    @try {
        UIPasteboard.generalPasteboard.string = self.reportText ?: @"";
        [self localToast:@"已复制全部内容（较长，建议改用「分享」发文件）"];
    } @catch (NSException *e) { }
}

- (void)onShare {
    @try {
        // 报告动辄上万字，粘贴容易被截断；这里优先「分享成一个 txt 文件」
        NSString *text = self.reportText ?: @"";
        NSURL *fileURL = nil;
        @try {
            NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:@"MikotoQuickGroup_report.txt"];
            if ([text writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
                fileURL = [NSURL fileURLWithPath:p];
            }
        } @catch (NSException *e) { }

        NSArray *items = fileURL ? @[fileURL, text] : @[text];
        UIActivityViewController *a =
            [[UIActivityViewController alloc] initWithActivityItems:items
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
    PJQGHidePanel();                       // v1.6：报告页是独立窗口的 root，不能 dismiss
    if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(); });
}

- (void)onClose {
    PJQGHidePanel();
}

@end

#pragma mark - 报告与手动输入的呈现

// 找出当前真正能 present 的 VC（hint 已失效则退回 keyWindow 根 VC）
// v1.6 起主流程已改用独立窗口，这里只作为最后退路保留
static __attribute__((unused)) UIViewController *PJQGTopPresentableVC(UIViewController *hint) {
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
    (void)from;   // v1.6：面板走独立窗口，不再依赖调用方传来的宿主
    NSString *t = [(text ?: @"(报告为空)") copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            PJQGReportViewController *r = [[PJQGReportViewController alloc] init];
            r.reportText    = t;
            r.autoCopy      = autoCopy;
            r.onManualInput = onManual;

            // ★ v1.6：直接当「独立窗口」的 root
            //   不再走 [宿主VC presentViewController:] —— 那么做只要宿主的层级不巧，
            //   UIKit 会静默失败（不抛异常、没界面），表现就是「点了没反应」。
            if (PJQGPanelWindowRef()) {
                PJQGShowPanel(r);
                PJQGLog(@"[report] 独立窗口展示成功，报告长度 %lu", (unsigned long)t.length);
                return;
            }
            // 连窗口都建不出来：退回原生 alert，至少保证「有界面 + 能复制」
            NSString *cut = t.length > 600 ? [t substringToIndex:600] : t;
            PJQGAlert(@"诊断报告（折叠）",
                      [cut stringByAppendingString:@"\n\n…点「复制全文」拿完整内容"], t);
        } @catch (NSException *e) {
            PJQGLog(@"[report] 展示失败: %@", e.reason);
            PJQGAlert(@"诊断报告（展示失败）",
                      [NSString stringWithFormat:@"%@\n\n%@", e.reason ?: @"?", t], t);
        }
    });
}

static void PJQGShowReportForHost(UIViewController *host, BOOL autoCopy, void (^onManual)(void)) {
    NSString *rep = nil;
    @try { rep = PJQGDiagnose(host); }
    @catch (NSException *e) { rep = [NSString stringWithFormat:@"生成诊断报告失败: %@", e.reason]; }
    @catch (...) { rep = @"生成诊断报告失败：非 Objective-C 异常"; }
    PJQGLog(@"[report] 生成完毕，长度 %lu", (unsigned long)rep.length);
    if (autoCopy) {
        // 只复制「关键结论」段 —— 全文太长会被聊天输入框截断（v1.4 就是这么丢数据的）
        @try { UIPasteboard.generalPasteboard.string = PJQGHeadOnly(rep ?: @""); } @catch (NSException *e) { }
    }
    if (rep.length == 0) {
        PJQGAlert(@"诊断报告为空", @"报告一个字都没生成出来，请把日志文件发我。", nil);
        return;
    }
    PJQGShowReport(host, rep, autoCopy, onManual);
}

// 手动输入会话 ID
static void PJQGRequestManualChatId(UIViewController *from, void (^done)(NSString *chatId)) {
    (void)from;   // v1.6：走面板窗口
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIAlertController *al = [UIAlertController
                alertControllerWithTitle:@"手动输入会话 ID"
                message:@"例如 wxid_xxx / xxxxx@chatroom / gh_xxx\n（可从诊断报告的「关键取值」里复制）"
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
            // ★ v1.6：走面板窗口，不再依赖调用方传来的 VC
            PJQGPresentOnPanel(al);
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
- (void)performGroupTap;
- (void)onDiagTap:(UIButton *)sender;
- (void)onLongPress:(UILongPressGestureRecognizer *)g;
- (void)onPan:(UIPanGestureRecognizer *)g;
- (void)applyChatId:(NSString *)chatId kind:(PJQGKind)kind setDefault:(BOOL)setDefault;
- (void)reportForMissingChatId;
- (void)showReportAutoCopy:(BOOL)autoCopy;
- (void)manualInput;
- (UIViewController *)topmost;
- (void)presentMenu;
- (void)runSelfTest;
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
    // ★ v1.6 核心改动：先把「按钮活着」这件事画到屏幕上，再去干重活。
    //   只要这行字出现，就证明按钮和 Hook 都是好的；之后无论走进哪个分支，
    //   屏幕上一定会继续出现结果或报错 —— 再也不会出现「点了完全没反应」。
    //   （0.12s 延迟是为了确保这一帧真的画出来了，再开始可能耗时的识别。）
    PJQGHUD(@"分组 ✓ 已响应 · 正在识别会话…", YES);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PJQGSTAGE(@"onTap");
        @try {
            [self performGroupTap];
        } @catch (NSException *e) {
            // ★ v1.7：异常逃到这一层，说明有一个我没堵住的洞。
            //   这一版把「阶段 + 调用栈 + 最近日志」一次性打出来并复制到剪贴板，
            //   弹窗里直接写阶段名 —— 下一轮就能精准定位，不用再猜。
            NSString *dig = PJQGDumpException(e);
            PJQGLog(@"[tap] ✗ 异常逃出 @阶段[%@]: %@", gPJQGStage, e.reason);
            PJQGHUD([NSString stringWithFormat:@"分组出错（阶段：%@）", gPJQGStage], NO);
            @try { UIPasteboard.generalPasteboard.string = dig; } @catch (NSException *x) { }
            NSString *brief = [NSString stringWithFormat:
                @"阶段   : %@\n原因   : %@\n\n完整诊断（含调用栈+日志）已复制到剪贴板，直接粘贴发我。",
                gPJQGStage ?: @"?", e.reason ?: e.name ?: @"未知"];
            PJQGAlert(@"分组出现异常", brief, dig);
        } @catch (...) {
            PJQGHUD(@"分组出错（非 Objective-C 异常）", NO);
        }
    });
}

// v1.6：把原来的同步逻辑挪到这里，每一步都在屏幕上留痕
// v1.7：每一步再各自包一层 @try —— 任何一个环节出问题都只会「这一步失败」，
//       不会再像以前那样整条链路崩掉，而且日志/弹窗里能看出是哪一步。
- (void)performGroupTap {
    UIViewController *vc = self.host;
    if (!vc) {
        PJQGHUD(@"拿不到聊天窗口对象（host 为空）", NO);
        return;
    }

    PJQGSTAGE(@"识别会话ID");
    NSString *how = nil;
    NSString *chatId = nil;
    @try { chatId = PJQGChatId(vc, &how); }
    @catch (NSException *e) { PJQGLog(@"[tap] 识别阶段异常: %@", e.reason); }
    PJQGLog(@"[tap] 会话ID=%@ (来源 %@) 结束阶段=%@", chatId ?: @"(空)", how ?: @"-", gPJQGStage);

    if (chatId.length == 0) {
        PJQGSTAGE(@"生成诊断报告");
        PJQGHUD(@"未识别到会话 → 打开诊断报告", NO);
        @try { [self reportForMissingChatId]; }
        @catch (NSException *e) {
            NSString *dig = PJQGDumpException(e);
            PJQGHUD([NSString stringWithFormat:@"报告生成异常（阶段：%@）", gPJQGStage], NO);
            @try { UIPasteboard.generalPasteboard.string = dig; } @catch (NSException *x) { }
            PJQGAlert(@"分组出现异常", [NSString stringWithFormat:@"阶段：%@\n原因：%@\n\n已复制到剪贴板。",
                                      gPJQGStage, e.reason ?: e.name ?: @"未知"], dig);
        }
        return;
    }

    PJQGSTAGE(@"读取默认分组");
    NSInteger d = -1;
    @try { d = PJQGDefaultKind(); } @catch (NSException *e) { }

    if (d < 0) {
        PJQGSTAGE(@"选择默认分组");
        PJQGHUD([NSString stringWithFormat:@"已识别：%@ · 请选分组", chatId], NO);
        @try { [self presentPickerSetDefault:YES]; }
        @catch (NSException *e) {
            NSString *dig = PJQGDumpException(e);
            @try { UIPasteboard.generalPasteboard.string = dig; } @catch (NSException *x) { }
            PJQGAlert(@"分组出现异常", [NSString stringWithFormat:@"阶段：%@\n原因：%@\n\n已复制到剪贴板。",
                                      gPJQGStage, e.reason ?: e.name ?: @"未知"], dig);
        }
        return;
    }

    PJQGSTAGE(@"写入分组");
    PJQGHUD([NSString stringWithFormat:@"%@ → 归入「%@」", chatId, PJQGKindName((PJQGKind)d)], NO);
    @try { [self applyChatId:chatId kind:(PJQGKind)d setDefault:NO]; }
    @catch (NSException *e) {
        NSString *dig = PJQGDumpException(e);
        PJQGHUD([NSString stringWithFormat:@"写入出错（阶段：%@）", gPJQGStage], NO);
        @try { UIPasteboard.generalPasteboard.string = dig; } @catch (NSException *x) { }
        PJQGAlert(@"分组出现异常", [NSString stringWithFormat:@"阶段：%@\n原因：%@\n\n已复制到剪贴板。",
                                  gPJQGStage, e.reason ?: e.name ?: @"未知"], dig);
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
    if (!host) { PJQGHUD(@"聊天窗口已关闭，放弃", NO); return; }
    if (setDefault) { PJQGSetDefaultKind(kind); [self refreshTitle]; }

    PJQGHUD(@"正在写入分组…", YES);
    NSString *detail = nil;
    PJQGApplyResult r = PJQGApplyNoProvider;
    PJQGSTAGE(@"写入:入口");
    @try { r = PJQGApply(chatId, kind, &detail); }
    @catch (NSException *e) {
        detail = [NSString stringWithFormat:@"%@（阶段 %@）", e.reason ?: e.name ?: @"?", gPJQGStage];
        r = PJQGApplyException;
    }
    if (r == PJQGApplyOK) {
        NSString *ok = [NSString stringWithFormat:@"✅ 已归入：%@%@",
                        PJQGKindName(kind), setDefault ? @"（并设为默认）" : @""];
        PJQGHUD(ok, NO);
        PJQGToast(host.view, ok);
        return;
    }
    NSString *fail = PJQGApplyResultText(r, detail);
    PJQGHUD([NSString stringWithFormat:@"❌ %@", fail], NO);
    PJQGToast(host.view, fail);
    // 失败：半秒后自动弹报告，方便直接复制发回
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self showReportAutoCopy:YES]; });
}

- (void)reportForMissingChatId {
    UIViewController *host = self.host;
    PJQGHUD(@"未能识别当前会话 → 生成诊断报告", NO);
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
    PJQGHidePanel();                      // v1.6：报告页现在是独立窗口，直接收掉
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PJQGRequestManualChatId(nil, ^(NSString *chatId) {
            PJQGChatAction *ss = ws;
            if (!ss || chatId.length == 0) return;
            NSInteger d = PJQGDefaultKind();
            if (d < 0) { [ss presentKindChooserForManualId:chatId]; return; }
            [ss applyChatId:chatId kind:(PJQGKind)d setDefault:NO];
        });
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
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"快速分组"
                                message:nil
                                preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"查看诊断报告（可复制）"
                        style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *a) { [self showReportAutoCopy:YES]; }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"自检（会话识别全过程·可复制）"
                        style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *a) { [self runSelfTest]; }]];

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

    // v1.6：默认关闭。开启后识别才会去碰微信的全局单例（会话管理器 / MMServiceCenter），
    //       危险性较高（可能卡住主线程），所以只作为「其他方法都识别不到」时的最后手段。
    [sheet addAction:[UIAlertAction actionWithTitle:
        (PJQGDeepIdentify() ? @"关闭深度识别（不碰微信全局单例）" : @"开启深度识别（最后手段）")
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
        PJQGSetDeepIdentify(!PJQGDeepIdentify());
        PJQGToast(self.host.view, PJQGDeepIdentify() ? @"深度识别已开启" : @"深度识别已关闭");
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
    // ★ v1.6：走面板窗口弹菜单 —— 原来 [vc presentViewController:] 在 vc 不合适时
    //   会静默失败（长按菜单也就「没反应」了）。
    PJQGPresentOnPanel(sheet);
}

// v1.6 新增：自检 —— 把「这个版本到底跑成什么样」一次性打出来并复制到剪贴板。
// 长按「分组」→ 自检，然后把弹出来的内容整段发回即可。
- (void)runSelfTest {
    PJQGHUD(@"自检中…", YES);
    UIViewController *vc = self.host;
    NSMutableString *s = [NSMutableString string];
    @try {
        [s appendFormat:@"===== MikotoQuickGroup v%@ 自检 =====\n", kPJQGVersion];
        [s appendFormat:@"时间      : %@\n", [NSDate date]];
        [s appendFormat:@"Bundle    : %@\n", NSBundle.mainBundle.bundleIdentifier ?: @"?"];
        [s appendFormat:@"微信版本  : %@ (%@)\n",
            [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
            [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?"];
        [s appendFormat:@"开关      : 安全模式=%@ 深度诊断=%@ 深度识别=%@ 悬浮球=%@\n",
            PJQGSafeMode() ? @"开" : @"关", PJQGDeepDiag() ? @"开" : @"关",
            PJQGDeepIdentify() ? @"开" : @"关", PJQGBubbleVisible() ? @"显示" : @"隐藏"];
        [s appendFormat:@"默认分组  : %@\n",
            PJQGDefaultKind() < 0 ? @"(未设置)" : PJQGKindName((PJQGKind)PJQGDefaultKind())];
        [s appendFormat:@"日志文件  : %@\n", PJQGLogPath()];
        [s appendFormat:@"当前阶段  : %@\n", gPJQGStage ?: @"-"];

        [s appendString:@"\n--- 环境 ---\n"];
        [s appendFormat:@"聊天窗口类: %@\n", vc ? NSStringFromClass([vc class]) : @"(host 为空)"];
        [s appendFormat:@"窗口已上屏: %@\n", (vc && vc.view.window) ? @"是" : @"否"];
        [s appendFormat:@"Mikoto类  : PJGroupDataModel=%@ PJMisakaManager=%@ PJGroupManager=%@ PJManagerModel=%@\n",
            NSClassFromString(@"PJGroupDataModel") ? @"✓" : @"✗",
            NSClassFromString(@"PJMisakaManager") ? @"✓" : @"✗",
            NSClassFromString(@"PJGroupManager") ? @"✓" : @"✗",
            NSClassFromString(@"PJManagerModel") ? @"✓" : @"✗"];
    } @catch (NSException *e) { [s appendFormat:@"(环境段异常: %@)\n", e.reason]; }

    @try {
        [s appendString:@"\n--- 写入接口 ---\n"];
        for (NSString *sn in @[ @"addGroupData:", @"addChatData:", @"addOtherGroupData:" ]) {
            NSString *how = nil;
            id p = PJQGFindProvider(NSSelectorFromString(sn), &how);
            [s appendFormat:@"%@ → %@ (%@)\n", sn,
                p ? NSStringFromClass([p class]) : @"(未找到)", how ?: @"-"];
        }
    } @catch (NSException *e) { [s appendFormat:@"(接口段异常: %@)\n", e.reason]; }

    @try {
        [s appendString:@"\n--- 会话识别全过程 ---\n"];
        NSMutableString *tr = [NSMutableString string];
        NSString *how = nil;
        NSString *cid = PJQGChatIdEx(vc, &how, tr);
        [s appendFormat:@"结果: %@   (来源 %@)\n", cid ?: @"(未取到)", how ?: @"-"];
        [s appendString:tr];
    } @catch (NSException *e) { [s appendFormat:@"(识阶段异常: %@)\n", e.reason]; }

    [s appendString:@"===== 以上整段复制发回即可 =====\n"];

    PJQGLog(@"[自检]\n%@", s);
    @try { UIPasteboard.generalPasteboard.string = s; } @catch (NSException *e) { }
    PJQGHUD(@"自检完成 ✓ 已复制到剪贴板", NO);
    PJQGShowReport(vc, s, NO, nil);
}

- (void)presentPickerSetDefault:(BOOL)setDefault {
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
                if (!host) { PJQGHUD(@"聊天窗口已关闭", NO); return; }
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
    PJQGPresentOnPanel(sheet);
}

- (void)presentKindChooserForManualId:(NSString *)chatId {
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
    PJQGPresentOnPanel(sheet);
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

// ★ v1.7：通用 setter 捕获（解决「动态捕获一直是 (无)」）
//   旧做法只挂了 11 个写死的选择子（setM_nsChatName: / setChatUserName: …），
//   微信 8.0.65 的 BaseMsgContentViewController 上可能一个都不存在 —— 这就是动态捕获一直为空的原因。
//   现在：把聊天窗口类（含父类链，止于 UIViewController）所有「参数为对象」的 setter 全挂上，
//   但只有在「值本身长得就像会话 ID（wxid_ / @chatroom / gh_ / @openim）」时才记录，
//   避免把 setTitle: 之类的普通字符串当成会话 ID 污染识别结果。
static void PJQGHookSetterStrict(id self, SEL _cmd, id arg) {
    @try {
        NSString *cid = nil;
        NSString *src = nil;
        if ([arg isKindOfClass:NSString.class]) {
            NSString *s = (NSString *)arg;
            if (s.length >= 6 && s.length <= 128 && PJQGLooksLikeChatIdScore(s) >= 15) {
                cid = s;
                src = NSStringFromSelector(_cmd);
            }
        } else if (arg) {
            NSString *u = PJQGUsrNameFromObject(arg);
            if (u.length && PJQGLooksLikeChatIdScore(u) >= 15) {
                cid = u;
                src = [NSString stringWithFormat:@"%@ → 对象成员", NSStringFromSelector(_cmd)];
            }
        }
        if (cid.length > 0) PJQGRememberCapturedChatId(self, cid, src);
    } @catch (NSException *e) { }

    IMP orig = PJQGOrigIMPFor(self, _cmd);
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, arg);
}

static void PJQGHookSettersGeneric(Class cls) {
    @try {
        if (!cls || !gPJQGMSHook) return;
        if (!gPJQGHookTable) gPJQGHookTable = [NSMutableDictionary dictionary];

        Class stopA = [UIViewController class];
        Class stopB = [UIResponder class];
        int guard = 0, hooked = 0;
        for (Class k = cls; k && k != Nil && guard++ < 10; k = class_getSuperclass(k)) {
            if (k == stopA || k == stopB || k == [NSObject class]) break;
            unsigned cnt = 0;
            Method *ms = class_copyMethodList(k, &cnt);
            if (!ms) continue;
            for (unsigned i = 0; i < cnt; i++) {
                SEL s = method_getName(ms[i]);
                const char *sn = sel_getName(s);
                if (!sn || strncmp(sn, "set", 3) != 0) continue;
                if (strlen(sn) < 5) continue;
                char c4 = sn[3];
                if (!(c4 >= 'A' && c4 <= 'Z')) continue;
                if (method_getNumberOfArguments(ms[i]) != 3) continue;
                char t[16] = {0};
                method_getArgumentType(ms[i], 2, t, sizeof(t));
                if (t[0] != '@') continue;
                if (t[1] == '?' || t[1] == '#') continue;    // 跳过 block / Class 参数
                NSString *key = [NSString stringWithFormat:@"%s|%s", class_getName(k), sn];
                if (gPJQGHookTable[key]) continue;
                @try {
                    IMP orig = NULL;
                    gPJQGMSHook(k, s, (IMP)PJQGHookSetterStrict, &orig);
                    if (orig) {
                        gPJQGHookTable[key] = [NSNumber numberWithUnsignedLongLong:(unsigned long long)(uintptr_t)orig];
                        hooked++;
                    }
                } @catch (NSException *e) { }
                if (hooked >= 160) break;
            }
            free(ms);
            if (hooked >= 160) break;
        }
        if (hooked) PJQGLog(@"[hook] 通用 setter 捕获 %s: 新挂 %d 个（表内共 %lu）",
                            class_getName(cls), hooked, (unsigned long)gPJQGHookTable.count);
    } @catch (NSException *e) {
        PJQGLog(@"[hook] 通用 setter 捕获异常: %@", e.reason);
    }
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

    // v1.7：再挂一遍「通用 setter 捕获」（只在值像会话 ID 时才记录）
    PJQGHookSettersGeneric(cls);
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
            if (c) { PJQGHookSetters(c); PJQGHookSettersGeneric(c); }
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
                "★ v1.6：点一下「分组」，屏幕上会立刻出现一条提示（「已响应 · 正在识别会话」），"
                "之后每一步都会继续显示结果。所以现在不会再出现「点了完全没反应」——"
                "如果连那条提示都没出现，说明插件没被加载进来。\n\n"
                "如果提示「未识别到会话」，会自动弹出报告并复制到剪贴板，直接发我即可；"
                "也可以长按「分组」→「自检」，把自检结果整段发我。\n\n日志：%@", PJQGLogPath()];
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
