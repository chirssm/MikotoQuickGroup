# MikotoQuickGroup

独立越狱插件 —— 在**微信聊天界面**加一个「分组」按钮，一键把当前会话归入 MikotoHelper 的指定分组，并**记住默认分组**。

> 本插件不修改 MikotoHelper.dylib 本体，而是通过 Objective-C 运行时（类名 + 选择子）调用它已加载的 Misaka 分组模块。两者零链接依赖。

---

## 一、功能行为

| 操作 | 行为 |
|---|---|
| **单击**「分组」按钮 | 若已设置默认分组 → 直接归入，Toast 提示「已归入：群聊（默认）」<br>若未设置 → 弹出选择器，**并把这次选择保存为默认分组** |
| **长按**按钮 | 菜单：`修改默认分组…` / `本次归入其他分组…` / `清除默认分组` / `取消` |
| 按钮标题 | 未设置时显示「分组」；设置后显示「分组·群聊」（跟随默认变化） |

可选分组：**群聊 / 聊天 / 其他**（对应 MikotoHelper `PJGroupDataModel` 的三栏 `misakaGroupArray` / `misakaChatArray` / `misakaOtherArray`）。

默认分组的持久化键：`NSUserDefaults` → `pjqg_default_kind`（`0`=群聊 `1`=聊天 `2`=其他，未设置 = 不存在该键）。

---

## 二、怎么拿到 `.dylib`（重点）

> ⚠️ **iOS 的 arm64 dylib 必须用 Apple 的 iOS SDK + clang 链接**，这套工具链只随 Xcode 发布。
> 因此在 **Windows 上无法直接编译产出 dylib**（没有 clang / Theos / Xcode / iOS SDK）。
> 下面三条路任选其一，都能拿到可注入的 `.dylib`。

### 路线 A：GitHub Actions 云编译（推荐，无需 Mac，免费）

已随附 `.github/workflows/build.yml`，配置好了 macOS runner + Theos + iOS SDK。

1. 在 GitHub 新建一个仓库（**公开**仓库的 macOS 分钟数免费）
2. 把 `MikotoQuickGroup/` 目录内**全部文件**（含 `.github/`）推上去
3. 进入仓库 **Actions** 标签页 → 选 `Build Tweak` → 点 **Run workflow**
4. 约 3~5 分钟后，在该次运行的页面底部 **Artifacts** 里下载：
   - `MikotoQuickGroup-dylib` ← **你要的 dylib**
   - `MikotoQuickGroup-deb`（可选，Cydia/Sileo 安装包）

```bash
# 命令行推仓库
git init && git add . && git commit -m "build"
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git branch -M main && git push -u origin main
```

### 路线 B：本机是 macOS

装了 Xcode Command Line Tools 即可，脚本自动搞定 Theos 与 SDK：

```bash
chmod +x build.sh
./build.sh dylib      # 只出 dylib（最快）
./build.sh            # dylib + deb
```

产物位置：`.theos/obj/**/MikotoQuickGroup.dylib`

### 路线 C：已有 Theos 的 Linux / 越狱设备

```bash
export THEOS=~/theos
make package                     # 产出 packages/*.deb（deb 内已含 dylib）
# 或只取 dylib
make && find .theos -name "*.dylib"
```

---

## 三、注入方式

### 方式 1：直接投放 dylib（你说的"手动注入"）

把 `MikotoQuickGroup.dylib` 重命名为 `MikotoQuickGroup.dylib`，用 Filza / SSH 放到：

| 越狱类型 | 路径 |
|---|---|
| rootless（Dopamine / palera1n rootless） | `/var/jb/Library/MobileSubstrate/DynamicLibraries/` |
| 有根（checkra1n / unc0ver） | `/Library/MobileSubstrate/DynamicLibraries/` |

同时需要在同目录放一个过滤 plist（随附的 `MikotoQuickGroup.plist`），内容：

```xml
{ Filter = { Bundles = ( "com.tencent.xin", "com.tencent.xinWeChat" ); }; }
```

放好后**杀掉微信进程重启**（或 `killall -9 WeChat`）。注入器会自动加载。

> 若设备要求签名：`ldid -S MikotoQuickGroup.dylib`（Theos 打包的版本已自动签名）。

### 方式 2：装 deb

```bash
dpkg -i packages/com.pj.mikotoquickgroup_1.0.0_iphoneos-arm64.deb
```

用 Sileo / Zebra 双击 deb 安装也可以。

---

## 四、验证是否生效

1. 打开微信任意一个聊天窗口 → 右上角应出现「**分组**」按钮
2. 长按有菜单、单击有 Toast
3. 查看日志确认加载：
   ```bash
   # 设备端
   tail -f /var/mobile/Containers/Data/Application/*/Documents/*.log
   # 或 Xcode / Console 过滤关键字
   "MikotoQuickGroup"
   ```
   正常会打印：`[MikotoQuickGroup] loaded. MikotoHelper(Misaka)=✓ 已检测到 default=-1`

---

## 五、必须按真机情况微调的 3 个点

本插件的**外部行为**（按钮、默认记忆、菜单）是完整自洽的；但它调用的 **MikotoHelper 内部方法签名**来自静态逆向，只有类名与选择子名是确证的，**参数类型与单例访问器名需真机确认**。全部不确定点已收敛到一个桥接函数里，改一处即可：

| # | 位置 | 待确认 | 确认方法 |
|---|---|---|---|
| 1 | `PJQGMisakaManager()` | 单例访问器真名（候选：`sharedInstance`/`sharedManager`/`defaultManager`/`manager`/`shared`） | Frida：`Object.keys(ObjC.classes.PJMisakaManager.$ownMethods)` |
| 2 | `PJQGApply()` | `addGroupData:` / `addChatData:` / `addOtherGroupData:` 的入参类型 | 断点看入参：是 NSString（会话 ID）还是对象 |
| 3 | `PJQGChatId()` | 会话 ID 所在字段（首选 `m_nsChatName`，已确证存在） | `vc.valueForKey_("m_nsChatName")` |

确认 Frida 片段：

```javascript
// 列出 Misaka 管理器的方法与单例
var C = ObjC.classes.PJMisakaManager;
console.log(Object.keys(C.$ownMethods).join("\n"));
// 逐个试探单例
["sharedInstance","sharedManager","defaultManager","manager","shared"].forEach(function(s){
  try { if (C[s]) console.log("singleton ->", s, C[s]()); } catch(e){}
});
```

另外 **持久化落点**也建议确认一下：如果你的设备上重启微信后分组失效，说明 `addGroupData:` 等只改了内存，需要改走 MikotoHelper 自己的配置写入路径（`PJSettingGroupVC` 背后的逻辑）。这一点在真机跑一次即可判断。

---

## 六、文件清单

```
MikotoQuickGroup/
├── Tweak.xm                          # 全部逻辑（hook + 桥接 + UI）
├── Makefile                          # Theos 工程（rootless 方案可选）
├── control                           # deb 元信息
├── MikotoQuickGroup.plist            # 注入过滤器（只注入微信）
├── build.sh                          # 本机一键构建（macOS/Linux）
├── .github/workflows/build.yml       # 云编译 → 直接下载 dylib
└── README.md                         # 本文
```

---

## 七、合规提醒

微信官方用户协议禁止修改客户端，注入代码存在账号被限制的风险。请仅用于**自有设备的安全研究与逆向学习**，勿用于分发、商业化或规避平台规则。本插件仅实现会话整理这一中性功能。
