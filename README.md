# MikotoQuickGroup

独立越狱插件 —— 在**微信聊天界面**加一个「分组」按钮，一键把当前会话归入 MikotoHelper 的指定分组，并**记住默认分组**。

> 本插件不修改 MikotoHelper.dylib 本体，而是通过 Objective-C 运行时（类名 + 选择子）调用它已加载的 Misaka 分组模块。两者零链接依赖。

---

## 〇、当前版本：v1.1（诊断增强版）

v1.0 反馈「完全没有反应、看不到界面」。v1.1 针对这个现象做了 6 项改造，**让它自己能说清是"没被加载"还是"没找到注入点"**：

| # | 改造 | 解决什么问题 |
|---|---|---|
| 1 | **启动自证弹窗 + 日志文件** | 微信启动 4 秒后弹「已加载 ✓」→ 弹出来就证明 dylib 被加载了；不弹就是没加载 |
| 2 | **多特征识别聊天窗口** | 不再写死 `BaseMsgContentViewController`，改为 hook `UIViewController` 后按「类名含 MsgContent/ChatViewController」或「响应 `m_nsChatName`」识别 —— 微信改类名不会失效 |
| 3 | **可拖动悬浮球** | 导航栏按钮之外再加一个悬浮球。微信用自绘导航栏时导航按钮可能被吞掉，悬浮球**一定看得见** |
| 4 | **运行时探测分组接口** | 自动扫描全部 `PJ*` 类 + 有界对象图搜索，找出真正实现 `addGroupData:` 的对象（不再假设是 `PJMisakaManager` 单例） |
| 5 | **参数类型自适应** | 读方法的 `type encoding`，判断该传 `NSString` 还是会话对象，自动取对应实例 |
| 6 | **诊断报告** | 长按按钮 →「查看诊断报告」，可一键复制。报告含：MikotoHelper 类是否加载、谁实现了分组方法、会话 ID、provider 来源、NSUserDefaults 相关键 |

### 自检日志文件

```
/var/mobile/Documents/MikotoQuickGroup.log
```

用 Filza 打开就能看到。**能打开这个文件 = dylib 确实被加载了。**

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
