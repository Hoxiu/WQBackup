# WQ 备份（WQ Backup）

一个不需要越狱的 iOS 应用数据备份工具，基于 **WQ Files** 的 worse_query 访问方式和备份实现思路重写。它把 **本机安装的应用** 和 **LiveContainer 里运行的应用** 放在两个完全分开的标签页里备份，互不混合。

**下载安装包**：[GitHub Releases](https://github.com/Hoxiu/WQBackup/releases/latest)（ad-hoc 签名，需要重新签名）  
**源码仓库**：[github.com/Hoxiu/WQBackup](https://github.com/Hoxiu/WQBackup)

- 本机应用：`本机应用` 标签页
- LiveContainer 应用：`LiveContainer` 标签页（独立窗口/标签栏位）
- 设置、日志、备份目录说明：`设置` 标签页

## 功能

**本机应用**

- 自动区分 **系统应用** 和 **我安装的应用**：列表按两类分区显示，顶部有“全部 / 我的应用 / 系统应用”筛选
- 每个应用显示对应的应用图标；取不到时回退为占位符号（不会显示空白）
- 列出已安装应用（名称、Bundle ID、数据目录、上次备份）
- 一键备份应用的 `Documents` 和 `Library`
- 每个应用独立的备份历史；支持恢复、校验、删除
- 分享为 ZIP（AirDrop、文件、邮件等）
- “全部备份”依次备份当前列表里的应用

**LiveContainer 应用（独立标签页）**

- 自动发现 LiveContainer 的数据容器和 App Group 共享容器
- 支持同一台设备安装多个 LiveContainer（例如 `com.kdt.livecontainer` 和 `com.kdt.LiveContainer2`）
- 支持一个应用有多个数据容器（LiveContainer 3.2+ 的“多容器”功能），每个容器单独一行、单独备份
- 兼容 LiveContainer 2.x/3.x 的数据目录：
  - `Documents/Applications/<应用>.app`
  - `Documents/Data/Application/<容器 UUID>`
  - `<App Group>/LiveContainer/Applications` 与 `.../Data/Application`
  - 旧版 `<应用包>/Data` 以及 `<应用包>/Documents|Library`
- 外部数据文件夹（通过 LiveContainer 的“外部容器”书签选择）无法由另一个 App 读取，会显示为不可备份并说明原因

**备份管理**

- 备份保存在本应用的 `Documents/WQBackups`：
  - `Local/<Bundle ID>/<时间>/` 本机应用
  - `LiveContainer/<Bundle ID>~<容器>~<哈希>/<时间>/` LiveContainer 应用
- 每份备份包含 `Documents/`、`Library/` 和 `.wqbbackup.plist` 清单
- 备份先写入隐藏暂存目录，全部完成并校验后才原子改名发布；中断不会留下“看起来可用”的半份备份
- 默认逐字节校验（可在设置里关闭）；恢复前会检查清单与文件数量
- 恢复采用“覆盖同名文件、保留备份中没有的文件”的合并方式，避免误删
- 备份文件夹通过 iOS 文件共享暴露：文件 App → 我的 iPhone → **WQ 备份** → `WQBackups`

## 要求

- iOS **26.0 – 27.3 beta 1**。Apple 在 **iOS 27.3 beta 2（24C5049d）** 修补了 worse_query，该版本及之后无法读取其他应用的数据。
- 签名工具必须保留 **App Group** 权限：
  - 推荐 AltStore、SideStore 或 Impactor（免费或付费 Apple ID 均可）
  - **Sideloadly 会去掉 App Group，无法使用**
- 不需要越狱。

数据布局已对照 iPhone 17（iOS 27.2）上的 LiveContainer 3.8.11 实际目录核对（`Documents/Applications/<Bundle ID>.app`、`Documents/Data/Application/<UUID>`、`Library/Preferences` 等）。

### 验证状态

- 主机回归：**87 项通过**（真实文件系统 fixture，覆盖本机/LiveContainer/App Group 多容器/旧版目录、系统/用户应用分类、备份、恢复、校验、ZIP、清单）。
- iOS arm64 严格编译通过（`-Wall -Wextra -Werror`），IPA 签名、entitlement、Info.plist 校验通过。
- 构建环境没有可用的 Apple 签名证书，因此这个 ad-hoc IPA **没有在真机上安装运行**；请用你的 AltStore / SideStore / Impactor 签名后安装验证。
- 图标优先取 iOS 的真实应用图标；iOS 26 上系统可能只返回空白占位图，此时会显示回退符号。LiveContainer 应用优先读取 `LCAppIconLight.png` 或应用包里的 PNG。

## 安装

[Releases](https://github.com/Hoxiu/WQBackup/releases/latest) 里的 `WQBackup.ipa` 是 **ad-hoc 签名**，仅用于交给签名工具重新签名：

1. 用 AltStore / SideStore / Impactor 选择 `WQBackup.ipa` 安装。
2. 保持 App Group 权限（这些工具会自动创建；组名可以不是 `group.com.wqbackup.app`，软件会使用实际拿到的那个组）。
3. 首次打开如果提示“没有获得 App Group”，说明签名工具去掉了该权限，请换一个签名工具重新安装。

> 为什么需要 App Group：worse_query 通过应用自己的 App Group 容器申请访问令牌（会短暂交换该组的 `Library/Caches`，结束即恢复）。没有 App Group 就无法读取其他应用的数据。

## 使用

1. 打开“本机应用”，等待列表出现（第一次可能需要几秒；如果提示需要扫描全部文件，按提示开始扫描）。
   - 备份前建议**完全关闭目标应用**。应用运行中写入数据会导致备份校验失败，软件会明确提示。
2. 轻点应用 → **立即备份**。
3. 轻点某条备份记录：恢复、校验、分享 ZIP、删除。
4. 打开“LiveContainer”标签页：只显示 LiveContainer 内的应用，和本机应用完全分开。
   - 每个数据容器单独一行；多容器应用会显示“容器: 名称”。
   - 备份前请先关闭 LiveContainer 中正在运行的那个应用。

### 恢复

- 恢复会覆盖目标应用同名的 `Documents`/`Library` 文件，**不会删除**备份里没有的文件。
- 必须先完全关闭目标应用；LiveContainer 应用还要关闭 LiveContainer 里对应的运行实例。
- 恢复完成后重新打开应用。`Library/Preferences` 由系统缓存，不重启应用可能看不到变化。

### “文件”App 中查看

设置 → 备份 → 在“文件”中查看：

```
文件 App → 我的 iPhone → WQ 备份 → WQBackups
    ├── Local
    └── LiveContainer
```

## 限制

- 只备份应用数据，不备份应用安装包（`.app`/IPA）本身：恢复前目标应用必须已经安装。
- 不备份 `tmp`、`SystemData`、钥匙串和系统级数据；`Library/Caches` 会包含在 `Library` 中，所以备份可能较大。登录令牌等存在钥匙串里的数据不会随备份迁移。
- 导出的 ZIP 会略过符号链接和特殊文件（备份文件夹本身保留它们）；需要完整保真时请直接拷贝备份文件夹。
- LiveContainer 的备份按数据容器目录区分：删除或重建某个数据容器后，旧备份不会自动出现在新容器下（文件仍在 `WQBackups/LiveContainer` 中，可在文件 App 里手动管理）。
- 备份存放在 WQ 备份自己的沙盒里；**删除 WQ 备份这个 App 会连同备份一起删除**。重要备份请及时分享/拷贝到“文件”App、电脑或网盘。
- LiveContainer 的“外部数据文件夹”使用安全书签，另一个 App 无法解析，因此无法备份（会标注原因）。
- 单个备份超过约 3.9 GB 时不能打包为一个 ZIP（ZIP 写入器上限 4 GB）；备份文件夹本身仍然完整，可在文件 App 中查看/拷贝。
- 设备锁屏且数据受保护时，个别文件可能读取失败；请解锁后重试。
- iOS 26 上 App Groups 父目录、System Data 等区域受限；本软件只需要各应用容器和 LiveContainer 的实际容器，通常不受影响。
- 首次列出应用时，如果系统不允许容器管理器枚举，会提示扫描全部文件；扫描可能需要几十分钟，且需要保持前台。

## 从源码构建

需要 macOS、Xcode（iOS 26+ SDK）和命令行工具：

```bash
cd WQBackup
./build.sh
```

产物：`WQBackup.ipa`（arm64，ad-hoc 签名，带 App Group entitlement）。

`build.sh` 会先运行主机回归测试 `tests/run_all_tests.sh`：

- 87 项备份/恢复/发现/分类/清单/ZIP 检查（真实文件系统 fixture，不需要设备）
- iOS arm64 严格编译（`-Wall -Wextra -Werror`）
- Info.plist、entitlement、LiveContainer 路径支持检查

需要跳过预检时：`WQB_SKIP_PREFLIGHT=1 ./build.sh`。

## 实现说明

- 沙盒访问：直接复用 **WQ Files 0.9.16** 的 `WQAccess`/`WQScanJournal`/`WQLaunchServices`/`WQArchive`/`WQAppsSupport` 访问与校验代码（GPL-3.0-or-later，保留了原文件头）。worse_query 由 Taj C（forcequitOS）发现。
- 本机应用发现：容器管理器/LaunchServices 数据库枚举 + 容器标识解析。
- LiveContainer 发现：不依赖固定 Bundle ID（本机就有 `com.kdt.livecontainer.R543VMPALT` 和 `com.kdt.LiveContainer2.R543VMPALT` 两个实例），而是检查容器的 `Documents/Applications` 布局和 App Group 内的 `LiveContainer/Applications`。
- 备份复制：`wq_copy_contents`/`wq_copy_tree_new` 跨容器复制，复制前后对源树做 SHA-256 元数据签名比较，确保复制期间源数据没有变化；可选的逐字节内容校验会与清单里的 `PartHashes` 对照。
- 全部文件操作都在本机完成，不上传网络；分享 ZIP 仅在用户主动点击分享时交给系统分享面板。

## 目录

```
WQBackup/
├── WQBackup.ipa                 # 构建产物（请重新签名后安装）
├── build.sh                     # 构建 + 预检 + 打包 + 签名校验
├── Info.plist / entitlements.plist
├── main.m
├── WQAccess.* WQAccessSafety.h WQScanJournal.h WQLaunchServices.* WQArchive.*
├── WQCore.* WQLocalization.* WQAppsSupport.h
├── WQBPaths.*                   # 备份清单、记录、目录布局
├── WQBDiscovery.*               # 本机应用 + LiveContainer 发现
├── WQBBackup.*                  # 备份/恢复/校验/ZIP
├── WQBUI.*                      # 两个标签页 + 详情 + 设置 + 扫描提示
├── icons/AppIcon1024.png
├── tests/                       # 主机回归测试
└── LICENSE                      # GPL-3.0
```

## 致谢与许可

- [WQ Files](https://github.com/kolbicz/WQFiles) by kolbicz — 沙盒访问、容器发现、备份校验的基础实现（GPL-3.0-or-later）。
- [worse_query](https://github.com/forcequitOS/worse_query) by Taj C（forcequitOS）— 无越狱容器访问技术。
- [LiveContainer](https://github.com/LiveContainer/LiveContainer) — 数据目录布局参考。

本项目以 **GPL-3.0-or-later** 发布，完整许可证见 `LICENSE`。修改和再分发请保留同样的许可与致谢。
