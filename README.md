# MikotoQuickGroup

独立越狱插件 —— 在**微信聊天界面**加一个「分组」按钮，一键把当前会话归入 MikotoHelper 的指定分组，并**记住默认分组**。

> 本插件不修改 MikotoHelper.dylib 本体，而是通过 Objective-C 运行时（类名 + 选择子）调用它已加载的 Misaka 分组模块。两者零链接依赖。

---

## 〇、版本演进

| 版本 | 针对的问题 | 关键改动 |
|---|---|---|
| v1.0 | —— | 首版：写死 `BaseMsgContentViewController` + 导航栏按钮 |
| v1.1 | 「完全没有反应」 | 启动自证弹窗 + 日志、多特征识别聊天窗口、可拖动悬浮球 |
| v1.2 | 「点了就闪退」 | 崩溃取证 + 自动安全模式 + 先验签后调用 |
| **v1.3** | 「**提示未能识别当前会话，且找不到诊断报告**」 | **报告随手可得（自动弹出 + 自动复制）+ 会话 ID 七级识别 + 动态捕获 + 手动输入兜底** |
| **v1.4** | 「**诊断报告只显示"生成诊断报告失败：Property Name should be baseResponse"**」 | **报告改为两段式（最小报告保证输出 + 完整报告尽力输出）；KVC 改为"成员变量直读优先"；消除裸 `respondsToSelector:`** |
| **v1.5** | 「**报告能出来了，但内容被聊天输入框截断；按钮仍然只是弹报告、没能真正分组**」 | **① 报告最前面加「关键结论」短段（几十行，整段粘贴不会被截断）；② 自动复制只复制这一段；③ 分享改为直接分享 txt 文件；④ 会话 ID 再加两级来源（微信全局服务链 + 消息回溯）；⑤ 完整报告每块独立 `@try`，「当前聊天窗口」段提到最前** |
| **v1.6** | 「**现在点了分组都没有反应了**」（比 v1.4 还糟：v1.4 至少弹报告，v1.5 什么都不出） | **① 点击后立刻在屏幕上画一条「已响应」提示（HUD），从此不可能再「没反应」；② 报告页/对话框全部改用独立 `UIWindow`（不再依赖 `presentViewController:`，消除静默失败）；③ 把 v1.5 新加的「微信全局服务链」从点击路径移出，默认关闭，只在长按菜单里显式开启；④ 单例探测加「返回类型必须是对象」校验（否则非对象返回值当 id 用会 SIGSEGV，`@try` 拦不住）；⑤ 新增会话 ID 来源「单条消息对象」；⑥ 长按菜单新增「自检」** |
| **v1.7** | 「**点分组弹出：分组出现异常 / Property Name should be baseRequest**」（微信本体抛的异常，MikotoHelper 里没有这个串） | **① 全链路「阶段追踪」：异常弹窗直接写「死在哪个阶段」；② 异常摘要 = 阶段 + 异常自己的调用栈 + 当前线程调用栈 + 最近 30 行日志，一次性复制到剪贴板；③ 识别链 / provider 查找 / 写入流程各自再包一层 `@try`；④ 新增「通用 setter 捕获」——把聊天窗口类（止于 UIViewController）所有对象型 setter 都挂上** |
| **v1.8** | 「**这一次微信都闪退了**」（v1.7 引入，`@try` 拦不住的进程级崩溃） | **紧急回退 + 加固：① 永久移除「通用 setter 捕获」——它会经 `%hook UIViewController`（全局 hook）把父类链上所有对象型 setter 全替换，含 `setView:` / `setTitle:` / `setDelegate:` 等 UIKit 热方法；② 永久禁用 `PJQGHookSettersEarly`——启动后 1.5s 在主线程遍历全 App 类并装最多 60×160 个 hook，主线程阻塞被 iOS watchdog 杀进程；③ hook 回调去掉成员变量挖掘（不再踩野指针），并加重入保护；④ 每个类只挂钩一次（`gPJQGHookedClasses`）；⑤ 彻底清除所有 `respondsToSelector:`——它会触发微信 protobuf 基类的 `+initialize` 并抛异常；⑥ 保留 v1.7 的阶段追踪与异常调用栈自诊断** |
| **v1.9** | 「**换个角度：走 Mikoto 自己的路径**」——用户截图证实 MikotoHelper 自带完整链路：聊天框底部「Mikoto」→「Misaka 用户设置」→「分组名称」→ 选分组，且**「用户设置」页上直接显示着「当前会话 ID」** | **① 新增最权威的会话 ID 来源（识别链 ⓪ 级）：`PJMisakaManager.settingVC.m_nsUsrName` —— MikotoHelper 自己认定的那个，不用再猜微信字段；② 新增「打开 Mikoto 分组列表（实验）」：直接复用它的 `PJMisakaSettingViewController` 与 `misaka_selectGroupAction` / `groupSettingFriendGroupIDAction` 等动作，把它自己的分组列表调出来，选完由它自己完成写入；③ 新增「探测 Mikoto 分组接口」：只读打印关键 selector 的实现者+完整签名、9 个目标类的运行时方法表、`PJMisakaManager` 实例的全部成员变量取值 —— 一键复制发回；④ 全部为只读 + 显式点击触发 + 危险调用哨兵** |
| **v2.0** | 「**第一步不成功；长按→探测 Mikoto 分组接口→微信直接闪退**」 | **① 修闪退：删除 `objc_copyClassList` 全表扫描** —— 旧版探测把微信全部类（3~5 万个）逐个查 18 个选择子 ≈ 近百万次运行时查询，主线程被占满触发 iOS watchdog（0x8badf00d）杀进程；现在只查 15 个已知类名，微秒级；**② 修「第一步不成功」：静态逆向证明 v1.9 的路是死的** —— `PJMisakaManager` 里**根本没有 `settingVC` 字段**（真名 `_settingVC`，且类型是微信自己的 `NewSettingViewController`），`m_nsUsrName` 也非真名（真名 `_m_nsUsrName`），所以单例路径必然失败；**③ 改为「自己造 Mikoto 的分组页」**：`PJGroupListViewController`（父类 `PJBaseViewController`，成员变量 `_userName` / `_type` / `_dataArray` / `_tableView`）→ 把当前会话 ID 写进 `_userName` → push 出来 → 点一下分组名即完成分组，写入逻辑完全由 MikotoHelper 执行；**④ 探测不再对 ivar 取值发消息**（v1.7 野指针 SIGSEGV 根因），只列名字+类型；**⑤ 报告同时落盘成 txt**（剪贴板会被聊天输入框截断） |
| **v2.0 的重要发现** | —— | 静态逆向：MikotoHelper 的 167 个 `PJ*` 类，`class_ro_t.baseMethods` **全部是 count=0 的空方法表**，但每个类都有一个真实的 `+[Class initialize]`（IMP 指向 `__text`）。**结论：这个 dylib 被加固过，实例方法是运行时在 `+initialize` 里动态注册的。** 所以任何「还没跟这个类打过交道」的进程里，`class_getInstanceMethod` 什么都查不到 —— 必须先给类发一条消息把 `+initialize` 跑掉（本版新增 `PJQGEnsureClassReady()`），否则查接口永远是「无」。 |
| **v3.0** | 「**这次变成闪退了，有没有简单一点的办法呢，改了很多次都不行啊**」 | **彻底换思路：不再创建 / 初始化 MikotoHelper 的任何东西，只「捡」它已经活着、正在服役的对象。** ① 删除 `PJQGEnsureClassReady()` 里的 `objc_msgSend(cls, @selector(class))`（**这就是 v2.0 一点就闪退的根因**：强制触发它的 `+initialize`，而那个初始化只有从它自己的入口进来才安全），现在该函数退化为纯查询；② 删除 `PJQGMakeMikotoGroupPage()`（自己 new 它的页面）整段实现；③ 新增 `PJQGScanLiveMikotoObjects()`：遍历所有 `UIWindow` 的视图树 + 读 `UIControl.allTargets` + 读 `UIBarButtonItem.target`，把所有类名以 `PJ`/含 `Misaka`/`Mikoto` 的**活对象**捞出来（全程只读，零创建零初始化）；④ 「① 一键打开 Mikoto 分组页」改为：屏幕上已有它的分组页就直接显示、已有它的 manager 就调它自己的分组动作（白名单 + 只调无参）、都没有就明确提示「先打开一次 Mikoto 界面再回来点」；⑤ 「② 看屏幕上有哪些 Mikoto 对象」只读报告，列活对象类名 + 方法名 + 关键类当前方法数 |
| **v4.0** | 「**还是不行；要不你直接修改 MIKOTOHELPER 这个插件实现快速分组吧**」 | **先用静态逆向确认「直接改 MikotoHelper」这条路不可行，再换成「自动记住你自己打开过的 Mikoto 页面」这条零风险路线。** ① 逆向结论：`MikotoHelper.dylib` 共 78 MB，`__TEXT,__text` 占 62 MB、`__DATA,__data` 占 15 MB，而 `__cstring` 只有 1.7 KB 且**全文没有任何中文**（"分组 / 设置 / 收纳"在 UTF-8 / UTF-16LE / GBK 三种编码下命中数全为 0）—— 说明 UI 文案走本地化文件、核心代码是加固的；167 个 `PJ*` 类的 `baseMethods` 全空，`__mod_init_func` 指向的初始化函数一开头就在用 `movz`/`movk` 解密数据。**直接改它 = 重打包一个 78 MB 的闭源加固包且找不到可改的代码，不可行**；② 新增 `PJQGCaptureLiveVC()`：在**已经存在**的 `viewDidAppear:` 钩子里顺手把用户亲手点开的 Mikoto 控制器（类名以 `PJ` 开头 / 含 `Misaka` / `Mikoto`）**强引用记下来**（上限 40 个，按指针去重）—— 不 new、不 alloc、不触发任何 `+initialize`，彻底绕开前几版闪退的根因；③ `PJQGOpenMikotoGroupList()` 新增第一优先级 ⓪：先用「已记住的分组名称页」→ 再试「已记住的用户设置页」（白名单动作 + 只调无参）→ 都没有才回落到 v3.0 的屏幕扫描；④ **单击「分组」改为直接打开 Mikoto 分组页**（老的「自己识别会话 ID 后写入」从来没成功过，退居长按菜单）；⑤ 「② 完整诊断快照」升级为最有价值的数据源：一次 `objc_getClassList` + 逐个 `class_copyMethodList`（纯元数据，安全）列出**全部 `PJ*` 类的运行时方法表**（含分组页真实方法名）+ 已记住的页面 + 屏幕活对象，自动复制并存 txt |
| **v4.0 的用法** | —— | **只需做一次**：① 装好新版并重启微信；② 在聊天框底部点「Mikoto」→「Misaka 用户设置」→「分组名称」，看到分组列表后**按返回键回到聊天窗口**（这一步是让插件记住这一页）；③ 以后单击聊天框里的「分组」按钮 → 直接回到那一页，点一下分组名即完成分组。若单击提示「还没有可用页面」，说明第 ② 步没做；若还不行，长按「分组」→「② 完整诊断快照」，把复制到的那一大段发回即可 —— 里面有 MikotoHelper 全部类的运行时方法名，据此能把「①」做成一定成功。 |

### v3.0 的关键转变：从「造对象」到「捡对象」

| | v2.0（失败） | v3.0 |
|---|---|---|
| 用 Mikoto 的类 | 自己 `alloc` + 自己触发 `+initialize` | **完全不碰它的类初始化**，只用它已经建好的实例 |
| 真机结果 | **一点就闪退** | 只在屏幕上已有其对象时动作，风险最低 |
| 闪退根因 | `objc_msgSend(cls, @selector(class))` 强制触发 `+initialize` | —— |
| 找不到对象时 | 崩 | 提示「先打开一次 Mikoto 界面」并给出只读报告 |

**核心认知**：MikotoHelper 的 `+initialize` **只有从它自己的入口（聊天框底部 Mikoto 按钮）被触发时才安全** —— 用户手动一路点进去全程不崩，就证明这条路它是能跑通的；外部代码强行触发 = 崩。所以正确姿势是**借它已经初始化好的对象用**，而不是自己造。

### v2.0 的两项修正（历史记录）

**修正 1 —— 闪退：探测不再扫全表**

| 旧（v1.9） | 新（v2.0） |
|---|---|
| `objc_copyClassList(&count)` 取微信全部类（旧机型 3~5 万个） | 只遍历 15 个「已知的 Mikoto 类名」（`PJQGKnownClassNames()`） |
| 18 个选择子 × 每类 `class_getInstanceMethod` + `class_getClassMethod` ≈ 近百万次 | 18 个选择子 × 15 类 = 270 次 |
| 主线程被占满 → watchdog 杀进程 → 「微信直接闪退」 | 微秒级完成，不可能触发 watchdog |

**修正 2 —— 「第一步不成功」：不再找 Mikoto 的单例，自己造它的页面**

v1.9 走的是 `PJMisakaManager` 单例 → `settingVC` ivar，静态逆向已证伪：

- `PJMisakaManager` 的真实成员变量里**没有** `settingVC`（真名 `_settingVC`，类型 `NewSettingViewController` —— 微信自己的设置页，跟 Misaka 分组无关）；
- `m_nsUsrName` 也不是真名（真名 `_m_nsUsrName`）。

所以 v1.9 的「①」永远拿不到实例，必然报「没找到 Misaka 用户设置实例」。

v2.0 的做法（不需要任何单例）：

```
PJGroupListViewController : PJBaseViewController
    _selectIndexPath(NSIndexPath) / _type(int) / _userName(NSString)
    _tableView(UITableView) / _dataArray(NSMutableArray)

① PJQGEnsureClassReady(cls)                     // 逼 +initialize，让方法真正注册进去
② 优先用它自己的构造器：initWithUserName: / initWithUserName:type: / …
③ 退化：alloc/init 后直接写 _userName（也试 _m_nsUsrName / setUserName: 等）
④ push 出来（找不到导航控制器就临时包一个 UINavigationController）
⑤ 用户在屏幕上点一下分组名 —— 写入完全由 MikotoHelper 自己的代码完成
```

**会话 ID 识别链的变化**：v1.9 加的「⓪ MikotoHelper 单例」已移除 —— 全局「最近一次捕获」可能属于别的会话，拿来当当前会话 ID 会**分错组**；现在只在「打开 Mikoto 分组页」时作为最后的兜底。

### v1.9 的 4 项改动（本次重点）

**依据 —— 用户真机截图（4 张）确认的三件事：**

1. 聊天输入框上方工具栏里，**Mikoto 插件已经有一个「Mikoto」按钮**（快捷回复 / **Mikoto** / 收藏 / 照片 / 拍摄）；
2. 点它弹出的是 MikotoHelper 自己的菜单：插件管理 / Misaka 设置 / **Misaka 用户设置** / 语音设置 / 清除当前窗口记录 / 消息库 / 文案库 / 消息屏蔽 / 备忘录 / 返回主页；
3. 进「Misaka 用户设置」后，页面上**直接写着「当前会话 ID：wxid_3204302043512」**，下面就是「分组名称 → 默认分组」；点进去是完整的**分组列表**（意向客户 39 / 货代同行 2859 / C 18 / 测评 26 / F 17 / 代理 89 / 不打广告的 10 / 美线客户 36 / 美线代理 26 / 询价客户 258 / 默认分组 / 不收纳该会话），右上角还有「添加」。

**这直接推翻了我之前两个假设：**

- ~~「会话 ID 要靠猜微信的字段名」~~ → **MikotoHelper 自己就知道**，它页面上就显示着；
- ~~「分组写入要自己拼 `addGroupData:` 调用」~~ → **它有现成 UI**，直接调出来用即可。

**改动：**

| # | 改动 |
|---|---|
| 1 | **会话 ID 识别链新增 ⓪ 级**（放在最前面，优先级最高）：从 `PJMisakaManager` 单例 → 成员变量 `settingVC`（即 `PJMisakaSettingViewController`）→ `m_nsUsrName` 读出。全程只读元数据，不走 KVC、不发消息 |
| 2 | **新增菜单「① 打开 Mikoto 分组列表（实验·首选）」**：找到 MikotoHelper 的「Misaka 用户设置」实例 → 优先用它的 `m_nsUsrName`（拿不到才用我们自己识别的结果，直接写进它的成员变量）→ 依次尝试 `misaka_selectGroupAction` / `groupSettingFriendGroupIDAction` / `groupNameAction` / `groupSettingGroupAction`（**只调无参的**，逐个独立 `@try`）→ 都不行就退化为把这个页面 push 出来，让你自己点「分组名称」 |
| 3 | **新增菜单「② 探测 Mikoto 分组接口（自动复制）」**：纯只读。输出 [A] 关键 selector 的实现者+完整 `typeEncoding`、[B] 9 个目标类的运行时方法表、[C] `PJMisakaManager` 实例全部成员变量取值、[D] `settingVC` 的成员变量取值、[E] 会话 ID 权威来源、[F] PJ* 类清单。一键复制发回即可 |
| 4 | 诊断报告的「关键结论」段新增「MikotoHelper 分组接口（简版）」：会话 ID 权威值 / settingVC 是否找到 / 5 个关键 selector 由谁实现 |

**静态逆向的收口结论（避免以后重复踩坑）**：对 `MikotoHelper.dylib` 做了完整的 ObjC 元数据重解析（`rev/objc2.py`、`rev/scan_methods.py`），结论是 —— `__objc_const` 里 167 个类的 `baseMethods` **全部是空表**，能扫到的 320 张方法表 / 4097 个方法里**不含** `addGroupData:`；而 `addGroupData:`、`misaka_selectGroupAction`、`groupSettingFriendGroupIDAction` 等**只出现在 `__objc_selrefs`（引用表）** 里 —— 即它们是**被 MikotoHelper 调用**的，**实现不在这个 dylib 里**（在另外的 Misaka 组件中）。**所以只能靠运行时探测来确定实现类与签名。**

| **v1.7** | 「**点分组弹出：分组出现异常 / Property Name should be baseRequest**」（微信本体抛的异常，MikotoHelper 里没有这个串） | **① 全链路「阶段追踪」：异常弹窗直接写「死在哪个阶段」；② 异常摘要 = 阶段 + 异常自己的调用栈 + 当前线程调用栈 + 最近 30 行日志，一次性复制到剪贴板；③ 识别链 / provider 查找 / 写入流程各自再包一层 `@try`，任何异常都只会变成「识别失败 → 报告」或「调用报错：xxx（阶段 yyy）」，不再冒到外层；④ 新增「通用 setter 捕获」——把聊天窗口类（止于 UIViewController）所有对象型 setter 都挂上，只在值确实像会话 ID（wxid_ / @chatroom / gh_ / @openim）时才记录，解决「动态捕获一直是 (无)」** |

### v1.7 的 5 项改动（本次重点）

v1.6 反馈：**点分组弹出「分组出现异常 / Property Name should be baseRequest」**（插件已加载、按钮正常、弹窗机制正常）。

先做了一件很关键的取证：在 78 MB 的 `MikotoHelper.dylib` 里全文搜索这个字符串（UTF-8 与 UTF-16LE 两种编码）——**一次都没命中**。结论：这个异常是**微信本体**抛的，说明我们的某个调用打进了微信内部（很可能是某个未知类的 `+initialize`，或 `addGroupData:` 内部去碰了微信的 protobuf/网络层）。

| # | 做法 | 说明 |
|---|---|---|
| 1 | **阶段追踪**：新增全局 `gPJQGStage`，`onTap` / 识别①~⑧ / provider 查找 / 写入入口 / 实际调用 / 刷新会话 每一步都写入当前阶段名 | 以前只能拿到一句原因，不知道死在哪；现在弹窗正文直接写「阶段：xxx」 |
| 2 | **异常摘要**：新增 `PJQGDumpException()` —— 阶段 + 异常名 + 原因 + `e.callStackSymbols`（异常自己的栈）+ `NSThread.callStackSymbols`（当前线程栈）+ 最近 30 行内存日志 | 调用栈里会直接出现微信 / MikotoHelper 的方法名，一眼看出是谁抛的；弹窗出现的同时**自动复制到剪贴板**，一次粘贴发回 |
| 3 | **三层兜底**：识别链（`PJQGChatIdEx`）、provider 查找（`PJQGFindProvider`）、写入流程（`PJQGApply`）各自整体再包一层 `@try` | 这三处以前只有「内部局部」保护，异常仍可能漏出去变成「分组出现异常」；现在最坏结果只是「识别失败 → 弹报告」或「❌ 调用报错：xxx（阶段 yyy）」 |
| 4 | **通用 setter 捕获**：`PJQGHookSettersGeneric()` 把聊天窗口类（含父类链，止于 `UIViewController`）所有「参数为对象」的 `setXxx:` 全部挂上 | 旧实现只挂了 11 个写死的选择子，微信 8.0.65 上一个都不存在，这就是「动态捕获一直是 (无)」的原因。新的只在**值本身像会话 ID**（`wxid_` / `@chatroom` / `gh_` / `@openim`）时才记录，不会把 `setTitle:` 的字符串当会话 ID |
| 5 | 每个 setter / 每步识别都写日志，「自检」里新增「当前阶段」一行 | 便于下一次直接定位 |

### v1.6 的 6 项改动（本次重点）

v1.5 反馈：**点了「分组」完全没反应**。

先用 git 拉 v1.4 源码与 v1.5 逐行比对，得到一个很硬的结论：

> **`onTap:` / `PJQGToast` / `PJQGShowReport` / `reportForMissingChatId` / `presentPickerSetDefault:` / `installBubble` 这些「点击 → 弹界面」的代码，v1.4 与 v1.5 一个字节都没改。**

所以「没反应」不是弹窗被改坏了，只能是**识别阶段**变了——而 v1.5 唯一动过的就是 `PJQGChatIdEx` 新增的 **⑦ 全局服务链**。它在 v1.4 里只存在于报告页，v1.5 被搬到了**点击路径**上，会去调 `MMSessionInfoManager` / `MMMsgLogicManager` / `MMServiceCenter getService:` 这些微信核心单例。在主线程上做这种重型探测，结果就是**卡住（界面冻住＝「没反应」）**，或者拿到非对象返回值直接 **SIGSEGV**。

| # | 根因 | v1.6 的处理 |
|---|---|---|
| 1 | 点击路径上新增了「碰微信核心单例」的探测 | ⑦ 全局服务链**移出默认路径**，改为 `PJQGDeepIdentify()`（默认 **NO**），只能在长按菜单里手动开 |
| 2 | `PJQGSingletonForClass` 把 `objc_msgSend` 的返回值直接当 `id` 用 | 调用前**强制校验 `method_getReturnType == '@'` 且无额外参数**；`PJQGFindProvider` 的单例循环同样加固，并改用 `class_getInstanceMethod` 取代会触发 `+initialize` 的 `respondsToSelector:` |
| 3 | 无论哪一步失败，屏幕上什么都看不到 | **点击后 0.12 秒先画 HUD**：「分组 ✓ 已响应 · 正在识别会话…」。之后每个分支都继续写 HUD（识别到 / 未识别到 / 正在写入 / ✅ 成功 / ❌ 失败原因）。**只要按钮活着，就一定有可见反馈**；连这条都不出现 → 说明插件根本没加载 |
| 4 | `[host presentViewController:]` 在宿主层级不巧时**静默失败** | 报告页、菜单、选择器、手动输入、兜底提示全部改走**独立 `UIWindow`**（`UIWindowLevelAlert+50`，报告页直接当 root，不走 present）。HUD 用另一层 `userInteractionEnabled=NO` 的穿透窗口 |
| 5 | 单聊里 `m_nsToUsr` 可能等于「我自己」 | 新增 ④·5「单条消息对象」（`m_lastMsgInNewArray` / `m_firstUnReadMsg` / `m_scrollTargetMsg` …）。取值规则：`m_nsRealChatUsr` 直接用；其它字段**只在值带 `@chatroom`/`@openim` 时才接受**，避免把账号自己当成会话 |
| 6 | 出问题时拿不到线索 | 长按菜单新增「**自检**」：版本号、开关状态、微信版本、聊天窗口类、MikotoHelper 类清单、写入接口 provider、**会话识别全过程（逐级命中）**，一次性打出来并**自动复制到剪贴板** |

### v1.5 的 5 项改动

v1.4 反馈：**报告出来了**（拿到了 `BaseMsgContentViewController` 的 142 个成员变量），但——
① 粘贴到聊天框时**被输入框长度限制截断**（只到第 ~110 条）；
② 按钮点下去**仍然只是弹报告**，说明会话 ID 没识别到，功能没生效。

| # | 问题 | v1.5 的处理 |
|---|---|---|
| 1 | 报告太长，粘贴必被截断 | 报告**最前面新增「关键结论」段**（窗口类 / 识别链各级命中情况 / MikotoHelper 类存在性 / 写入接口 provider / 会话 ID 候选字段 / 关键取值），只有几十行 |
| 2 | 自动复制复制的是全文 | 自动复制**只复制「关键结论」段**（新增 `PJQGHeadOnly`），保证一次粘贴就能发回 |
| 3 | 全文没法发 | 「分享」改为**先写成 txt 再分享文件**（微信可直接发文件），不再依赖粘贴 |
| 4 | 会话 ID 仍然识别不到 | 新增 **⑦ 全局服务链**（`MMSessionInfoManager` / `MMMsgLogicManager` / `MMServiceCenter getService:` …）与 **⑧ 消息回溯**（从 `m_arrMessageNodeData` 的消息对象里取 `m_nsToUsr`/`m_nsFromUsr`）；`m_delegate` 也加入子对象链 |
| 5 | 完整报告可能被某一块炸掉 | `PJQGDiagnoseDetail` **每块独立 `@try`**，「当前聊天窗口」段（识别过程 + 取值）**提到最前面**，后面炸了也不丢关键信息 |

### v1.4 的 3 项修复

v1.3 反馈：报告页**只显示一行错误** —— `生成诊断报告失败：Property Name should be baseResponse`，没有任何可用线索。

那条报错是**微信自己的 protobuf 基类**抛出来的：它把 `-valueForUndefinedKey:` 重写成直接抛异常（原文就是 `Property Name should be baseResponse`）。也就是说，我们用 KVC 读了一个微信对象上不存在的键，异常从某个**没被 `@try` 包住的语句**里逃出来，把整份报告炸掉了。

| # | 根因 | v1.4 的处理 |
|---|---|---|
| 1 | **KVC 取不存在的键 → 抛异常** | `PJQGSafeObjectForKey`：**先查成员变量，有就 `object_getIvar` 直读**（完全不经过 KVC）；只有确认类真的实现了返回对象的 getter，才允许走 `valueForKey:`；全程 `@try` |
| 2 | **裸 `respondsToSelector:`** | 它会触发目标类的 `+initialize`（MikotoHelper 的 `+initialize` 会去碰微信的 protobuf 对象，可能抛异常）。`PJQGFindProvider` 的单例探测循环整体加了 `@try`，并把异常写进日志 |
| 3 | **一条语句抛异常 = 整份报告报废** | 报告改为**两段式**：① 先输出「**最小报告**」—— 只走运行时元数据（不读对象内存、不发消息给未知类，绝不抛异常），**包含定位会话 ID 所需的全部信息**；② 再尽力追加「完整报告」，炸了也只留一行说明 |

**最小报告里一定有的东西**（这是通关钥匙）：

```
--- 当前聊天窗口（元数据，保证输出） ---
  类名: WeChatClassXXX
  匹配原因: 类名含特征词（…MsgContent…）
  动态捕获: (无)
  成员变量名称全表:
  [WeChatClassXXX] 42 个
    m_nsChatName : @"NSString"
    m_oContact : @"CClassContact"
    …（该类的全部成员变量名 + 类型）
```

有了这张表，就能一眼看出会话 ID 到底存在哪个字段，不用再猜。

### v1.3 的 6 项改动

v1.2 反馈：**按钮能点、不闪退了，但提示"未能识别当前会话"，而且照着提示去找诊断报告却找不到。**

定位到两个真实缺陷：

| # | 缺陷 | 说明 |
|---|---|---|
| 1 | **提示与行为不符** | `onTap:` 里会话 ID 为空时只弹了个 Toast 说「见诊断报告」，**代码里根本没有把报告给出来** |
| 2 | **报告入口太隐蔽 + 日志写不进去** | 报告只能靠「长按悬浮球 → 接口探测」；日志写在 `/var/mobile/Documents/`，而微信是沙盒进程，**该路径不可写**，日志文件压根没生成 |

v1.3 的处理：

| # | 改动 | 效果 |
|---|---|---|
| 1 | **失败自动弹全屏报告** | 会话 ID 识别失败 / 归入失败 → `0.35s` 后自动弹出「诊断报告」全屏页：可滚动、可选中、一键复制 |
| 2 | **自动复制到剪贴板** | 弹出同时把报告写入剪贴板并提示「已复制」→ 直接粘贴就能发出来，不用去文件系统找 |
| 3 | **报告入口显性化** | 悬浮球旁新增蓝色「**诊**」小按钮，单击即开报告；长按「分组」的菜单**第一项**就是「查看诊断报告」 |
| 4 | **会话 ID 七级识别链** | ① 动态捕获 ② KVC ③ 选择子探测 ④ 成员变量扫描（名字打分 + 值形态打分）⑤ 逻辑控制器/联系人/会话对象链 ⑥ 全局捕获提示 ⑦ 手动输入 |
| 5 | **动态捕获 setter** | 运行时 `dlsym` 解析 `MSHookMessageEx`（取不到自动降级），挂住 `setM_nsChatName:` / `setChatUserName:` / `setM_oContact:` 等 setter，**记录微信自己写进来的会话 ID**；启动后 1.5s 就先把所有 `*MsgContent*` 类挂上，提高命中率 |
| 6 | **手动输入兜底** | 识别不到时可直接手填会话 ID（`wxid_xxx` / `xxx@chatroom` / `gh_xxx`），功能不被卡住 |

### 诊断报告里有什么（关键）

报告是自足的，**不需要再去找日志文件**。其中这几段是定位问题的关键：

```
--- 当前聊天窗口 ---
  类名: BaseMsgContentViewController
  匹配原因: 类名含特征词（BaseMsgContentViewController）
  动态捕获: (无)
  识别过程:
    ① 动态捕获 = (无)
    ② KVC m_nsChatName = (无)
    ③ 选择子探测 = (无)
    ④ 成员变量扫描 = (无)
    ⑤ m_logicController (BaseMsgContentLogicController) = 未取到
    ⇒ 结果: (未取到)  (来源 -)

  成员变量名称全表（只读元数据，可据此定位会话ID字段）:
    [BaseMsgContentViewController] 128 个
      m_nsChatName : @"NSString"
      m_oContact : @"CContact"
      ...
  关键成员取值:
    m_nsChatName = "wxid_xxxxx"
    m_oContact : CContact
--- 谁实现了这些方法 ---
--- 方法签名（决定能不能调用） ---
```

**「成员变量名称全表」只读元数据、不碰内存，绝对安全**；「关键成员取值」会读对象内存，若因此崩溃，下次启动会自动关闭「深度诊断」并在弹窗里说明（功能不受影响）。

### 自检日志文件

```
沙盒 Documents/MikotoQuickGroup.log     ← 实际可用路径（报告里会写明）
```
v1.3 会依次尝试「App 沙盒 Documents → App tmp → `/var/mobile/Documents` → `/tmp`」，
**报告开头就列出每个候选路径的存在性与可写性**，并写明实际用了哪个。
崩溃调用栈另外追加在 `/tmp/MikotoQuickGroup_crash.log`（用裸 `open/write` 写，不依赖 Foundation）。

### 安全模式

- **自动进入**：检测到上次运行崩在危险调用上
- **手动切换**：长按按钮 →「进入安全模式 / 解除安全模式」
- 还有其他可调项：**深度诊断开关**（是否读取对象成员变量）、悬浮球显隐

### 接口探测（只读）

长按按钮 →「**查看诊断报告**」→ 弹窗可「复制全文」。输出包含**完整方法签名**，例如：

```
· addGroupData: (1 个类)
   -[PJGroupDataModel addGroupData:] 返回=v 参数(3): @0 :8 @"PJGroupModel"16
```

这一行就能确定该传 `NSString` 还是 `PJGroupModel` 对象 —— 拿到它就能把桥接层一次改对。


---

## 一、功能行为

| 操作 | 行为 |
|---|---|
| **单击**按钮 / 悬浮球 | 若已设置默认分组 → 直接归入，Toast「已归入：群聊（默认）」<br>若未设置 → 弹选择器，**并把这次选择保存为默认分组** |
| **长按**按钮 / 悬浮球 | 菜单：`修改默认分组…` / `本次归入其他分组…` / `清除默认分组` / `查看诊断报告` / `隐藏悬浮球` / `取消` |
| 导航栏标题 | 未设置显示「分组」；设置后显示「分组·群聊」 |
| 悬浮球标题 | 未设置显示「分组」；设置后显示「群聊」/「聊天」/「其他」 |
| 拖动悬浮球 | 按住拖动，自动吸附在屏幕内（右侧边缘） |

可选分组：**群聊 / 聊天 / 其他**（对应 MikotoHelper `PJGroupDataModel` 的三栏 `misakaGroupArray` / `misakaChatArray` / `misakaOtherArray`）。

持久化键（均在 `NSUserDefaults`）：

| 键 | 含义 |
|---|---|
| `pjqg_default_kind` | `0`=群聊 `1`=聊天 `2`=其他，不存在 = 未设置 |
| `pjqg_bubble_visible` | 悬浮球是否显示（默认 `YES`） |
| `pjqg_silent_alert` | 设为 `YES` 后不再弹启动自证窗 |

---

## 二、安装（三条路，任选其一）

> ⚠️ **iOS 的 arm64 dylib 必须用 Apple iOS SDK + clang 链接**，Windows 上无法产出。
> 本目录已附编译好的产物，直接拿走即可；要自己重编见第四节。

### 方式 1：装 deb（最省事）

```bash
dpkg -i MikotoQuickGroup.deb
```

或用 Sileo / Zebra 直接点开安装。deb 是 **rootless** 布局（装到 `/var/jb/...`），
若你的越狱**有根**（checkra1n / unc0ver），请用方式 2 手动投放。

### 方式 2：手动投放 dylib（你说的"手动注入"）

**must 两件事一起做**，只放 dylib 不放 plist 是**不会加载**的：

```
① MikotoQuickGroup.dylib
② MikotoQuickGroup.plist        ← 过滤条件，不能少
```

放到同一目录：

| 越狱类型 | 目录 |
|---|---|
| rootless（Dopamine / palera1n） | `/var/jb/Library/MobileSubstrate/DynamicLibraries/` |
| 有根（checkra1n / unc0ver） | `/Library/MobileSubstrate/DynamicLibraries/` |

然后重启微信进程：

```bash
killall -9 WeChat
```

> 若设备报签名问题：`ldid -S MikotoQuickGroup.dylib`（Theos 打出的版本已签好）。
>
> 若用的是 **TrollFools / 注入工具**（把 dylib 直接塞进 App 包）：**不需要 plist**，直接注入后重开 App 即可。

### 方式 3：过滤条件对不上时

插件的过滤条件是：

```xml
{ Filter = { Bundles = ( "com.tencent.xin", "com.tencent.xinWeChat",
                         "com.tencent.xin.debug", "com.tencent.xin.dev" ); }; }
```

若你的微信是**多开版 / 改包名版**，plist 里的 bundle id 就对不上，插件不会加载。
处理办法：把 plist 内容换成按可执行文件名匹配（可执行名一般是 `WeChat`）：

```xml
{ Filter = { Executables = ( "WeChat" ); }; }
```

---

## 三、验证是否生效（按顺序做）

**第 1 步：确认 dylib 被加载了**

重启微信，等 4 秒 —— 会弹一个「MikotoQuickGroup 已加载 ✓」的窗。
- **弹了** → 加载成功，往下走
- **没弹** → dylib 没被加载。原因只会是这几种：plist 没放 / 放错目录 / 目录不属于你的越狱类型 / bundle id 对不上 / 没重启微信

也可以看日志文件：

```
/var/mobile/Documents/MikotoQuickGroup.log
```

正常开头是：

```
================================================
MikotoQuickGroup v1.1 已注入 (pid=1234)
bundle = com.tencent.xin
MikotoHelper(Misaka) = ✓ 已检测到
日志文件 = /var/mobile/Documents/MikotoQuickGroup.log
================================================
```

**第 2 步：确认按钮出现**

进任意聊天窗口 → 右侧应看到**悬浮球「分组」**（一定能看到），右上角还应有「分组」导航按钮。

**第 3 步：确认分组接口可用**

长按按钮 →「查看诊断报告」。报告里这两行是关键：

```
--- 对象图查找结果 ---
  addGroupData:        PJGroupDataModel  via 单例 PJGroupDataModel.sharedInstance
  rebuildMainSessions: NewMainFrameViewController  via MainFrameViewController...
```

- 如果显示 `(未找到)` → 把整份报告复制发我，我按报告里的类名清单改桥接层
- 如果找到了但点按钮没效果 → 报告里的「参数类型」那行会告诉我该传什么

---

## 四、自己重新编译

### 路线 A：GitHub Actions（推荐，无需 Mac，免费）

仓库：`https://github.com/chirssm/MikotoQuickGroup`

1. 改完 `Tweak.xm` 推到 `main`
2. 仓库 **Actions** → `Build Tweak`（push 会自动触发）
3. 约 3~5 分钟后，在运行页面底部 **Artifacts** 下载 `MikotoQuickGroup-dylib`

> 注意：工作流里已加「复制到 dist/」步骤，因为 `upload-artifact` 默认**跳过隐藏目录** `.theos`。

### 路线 B：本机 macOS

```bash
chmod +x build.sh
./build.sh dylib      # 只出 dylib（最快）
./build.sh            # dylib + deb
```

### 路线 C：Linux / 越狱设备的 Theos

```bash
export THEOS=~/theos
make package                                     # packages/*.deb
make && find .theos -name "*.dylib"              # 只取 dylib
```

---

## 五、产物校验（v1.0 实测结果）

| 项目 | 结果 |
|---|---|
| 构建 | ✅ 成功（macOS-14 runner + Theos + iOS SDK） |
| 架构 | **FAT 通用二进制：arm64 + arm64e 双切片** |
| 类型 | `MH_DYLIB`（filetype 6），含 `LC_CODE_SIGNATURE` |
| 链接 | UIKit / Foundation / CoreFoundation / **CydiaSubstrate** |

---

## 六、仍然需要真机确认的点

v1.1 已把「猜」的部分改成运行时探测，但下列事实只有设备能回答。**先跑诊断报告**，多数能自答：

| # | 项目 | v1.1 的处理 | 报告里的对应行 |
|---|---|---|---|
| 1 | 分组接口挂在哪个类 | 扫描全部 `PJ*` + 对象图搜索 | `--- 谁实现了分组方法 ---` |
| 2 | 单例访问器真名 | 10 个候选自动试探 | `对象图查找结果 → via` |
| 3 | 入参是 NSString 还是会话对象 | 读 `type encoding` 自动判断 | `[apply] 参数类型 = ...` |
| 4 | 会话 ID 字段 | 6 个字段 + logicController 兜底 | `当前聊天窗口 → 会话ID` |
| 5 | 分组是否落盘 | 未知 | 重启微信后看默认是否还在 |

若 1~4 报告里都正常但点了没反应，或**重启后分组丢失**，把诊断报告发我 —— 第 5 项（落盘路径）需要改走 MikotoHelper 自己的配置写入链路，那需要报告里的 `NSUserDefaults 相关键` 段来定位。

Frida 备用命令：

```javascript
var C = ObjC.classes.PJGroupDataModel;
console.log(Object.keys(C.$ownMethods).join("\n"));
["sharedInstance","sharedManager","defaultManager","manager","shared"]
  .forEach(function(s){ try { if (C[s]) console.log(s, "->", C[s]()); } catch(e){} });
```

---

## 七、文件清单

```
MikotoQuickGroup/
├── MikotoQuickGroup.dylib            # ★ 编译好的插件（arm64 + arm64e FAT）
├── MikotoQuickGroup.deb              # ★ 安装包（rootless 布局）
├── Tweak.xm                          # 全部逻辑（hook + 运行时探测 + UI + 诊断）
├── Makefile                          # Theos 工程（THEOS_PACKAGE_SCHEME=rootless）
├── control                           # deb 元信息
├── MikotoQuickGroup.plist            # 注入过滤器（不能少！）
├── build.sh                          # 本机一键构建（macOS/Linux）
├── .github/workflows/build.yml       # 云编译 → 直接下载 dylib
└── README.md                         # 本文
```

---

## 八、合规提醒

微信官方用户协议禁止修改客户端，注入代码存在账号被限制的风险。请仅用于**自有设备的安全研究与逆向学习**，勿用于分发、商业化或规避平台规则。本插件仅实现会话整理这一中性功能。
