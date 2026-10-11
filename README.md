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

### v1.5 的 5 项改动（本次重点）

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
