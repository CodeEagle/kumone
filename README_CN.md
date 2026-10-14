<div align="right">

[English](README.md) | **简体中文**

</div>

<div align="center">

<img src="docs/icon.png" width="140" alt="MiuMiu" />

# MiuMiu

**基于 [Kumone](https://github.com/missuo/kumone) fork 的原生 macOS 音乐客户端。**

AppKit + SwiftUI · TCA · APlay · Metal 动态背景

[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue?logo=apple)](#构建与运行)
[![Swift](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](Package.swift)
[![License](https://img.shields.io/badge/license-LGPL--3.0--only-orange)](LICENSE)

[源码分支](https://github.com/CodeEagle/kumone/tree/rewrite/appkit) · [配置文档](docs/config-ui.md)

</div>

MiuMiu 延续 Kumone 的网易云音乐功能，围绕原生 AppKit 窗口、统一状态管理、
新的播放引擎和连续的封面转场，重新打磨 macOS 客户端。这个分支关注浏览、
播放，以及从 minibar 到正在播放页面的完整体验。

项目与应用的对外名称统一为 **MiuMiu**。仓库、Swift 模块、Bundle Identifier
及 `~/.config/kumone` 配置目录沿用现有名称，以保持兼容。

## Fork 之后的变更

| 方向 | 本分支的变更 |
| --- | --- |
| 架构 | AppKit 管理窗口与菜单；统一 TCA Store；拆分 Core、TCA、UI 与 Shaders 模块 |
| 播放 | 接入 APlay；缓存感知流式播放；CDN 主机回退；优化加载、缓冲与音源回退 |
| 音源 | 抽象 MusicProvider；部分接入 QQ、酷我匿名接口；支持配置自托管 LX 解析服务 |
| 正在播放 | 经典、沉浸、黑胶、极简模式；Zen 行为；普通播放与漫游控制区重新布局 |
| 动效 | 封面、文字、标签与控制按钮的双向 Hero 转场；统一卡片 scale 点击反馈 |
| 背景 | 窗口共享 Metal 渲染；封面取色；可选音乐响应；Shader 导入与透明度控制 |
| 系统集成 | 菜单栏播放器、桌面歌词、原生工具栏、本地／全局快捷键、媒体键与控制中心 |
| 自定义 | YAML 页面、主题、状态绑定、动作与按键映射，支持热更新 |
| 稳定性 | 缓存与资源生命周期收敛；导航、渲染、传输及原生窗口回归验证 |
| 国际化 | 补齐 fork 新增功能的简体中文与英文界面 |

### 原生窗口与应用架构

- macOS 使用 AppKit 管理应用、窗口、工具栏、菜单和控制器，内容页面继续使用 SwiftUI。
- 将应用与功能状态迁移到 TCA Reducer，通过依赖客户端和共享 Store 统一播放、导航、设置及系统操作。
- 拆分 API／模型／播放／存储、功能状态与页面、配置驱动 UI、Metal Shader 等 SwiftPM 模块。
- 搜索框接入原生工具栏，调整侧栏开关与返回按钮行为，并设置主窗口最小尺寸。
- 沉浸播放隐藏系统窗口按钮时，仍保留 ⌘W 的标准关闭行为。

### 播放引擎与流式缓存

- 将原有 AVPlayer 播放路径替换为 [APlay](https://github.com/CodeEagle/APlay)，当前固定版本为 **2.2.3**。
- 接入引擎的流式缓存，完整缓存的音频再次播放时复用本地数据；增加存储占用与缓存清理设置。
- 加入网易云 CDN 双主机回退，保留签名 URL、Range 请求与原始缓存标识，并限制重试次数。
- 优化缓冲、文件末尾与播放结束处理；加载阶段即发布正在播放元数据，选择新歌曲时立即暂停上一首。
- 保留可配置的音源回退，并在使用回退音源时展示来源标签。
- 私人漫游与心动模式加入可配置的最近播放过滤，减少短期重复推荐。

其中部分传输改进来自上游移植，并适配了本分支的 APlay／AppKit 架构。
具体范围与验证见[上游 macOS 功能移植记录](docs/upstream-macos-ports.md)。

### 音乐服务抽象与多音源

页面与功能通过 MusicProvider 协议访问音乐服务，统一处理不同来源的歌曲 ID，
并通过可选能力区分各服务支持的操作。

| 音源 | 已实现范围 | 当前边界 |
| --- | --- | --- |
| 网易云 | 主要账号、推荐、音乐库、搜索、播放、歌词、FM 与歌单操作 | 可用性与音质取决于账号和上游服务 |
| QQ 音乐 | 匿名热搜、排行榜、推荐歌单与歌词 | 尚未实现登录、搜索及直接播放 |
| 酷我 | 匿名单曲搜索、搜索建议、部分排行榜与播放地址转换 | 转换接口提供标准 MP3；不支持账号／音乐库管理与歌词 |
| LX | 通过配置的自托管 LX-Source 服务解析播放地址，并参与解锁回退链路 | 需要自己的服务地址；不是完整的推荐或账号服务 |

QQ、酷我与 LX 为部分能力接入，目前没有与网易云等同的功能覆盖。网易云请求
仍使用原生 Swift 实现的 weapi／eapi；可选 LX 解析使用用户配置的外部服务。

### 正在播放与 minibar

- 重新整理 Liquid Glass minibar 的两行布局，对齐歌曲信息、状态标签、播放控制与工具按钮。
- VIP 与音质标签常驻，统一边框与高度，不可用时置灰；Like 放在 minibar 最右端。
- 普通播放与私人漫游模式的播放／暂停按钮保持横向正中，不因两侧控件数量不同而偏移。
- Title 独立居中，VIP、音质与漫游标签跟随在后方，并为标签预留宽度；较长的歌手／专辑信息允许换行，保留详情跳转。
- 调整黑胶展示和 Zen 行为：封面与信息向中心移动，控制区渐隐，保留控件身份以避免重新创建引起跳变。
- 操作按钮使用半透明黑色背景，改善浅色 Shader 下的图标可读性。

### Hero 转场与导航

- minibar 与正在播放之间，以及卡片／歌曲封面与歌单、专辑、歌手详情之间，加入双向封面 Hero 转场。
- 在对应场景中，让 Title、Artist、VIP／音质标签、播放按钮、歌词按钮、AirPlay 与漫游状态随封面一起过渡。
- 飞行期间隐藏对应起点与终点，避免同时出现两个封面，以及按钮背景闪烁。
- 卡片转场复用当前缓存封面；播放器封面放大时保留中途升级高清图片的处理。
- 返回 minibar 时逐步转换文字长度、裁剪、颜色和字体，减少落地瞬间的闪烁。
- 进入歌单时延后挂载歌曲列表，避免列表布局阻塞封面动画。
- 卡片点击统一使用 scale 缩放反馈，并修正雷达歌单与推荐艺人的返回位置和尺寸。

### Metal Shader 与背景可读性

- 在窗口层共享 Metal 背景，让侧栏与页面透出同一幅画面，减少重复的全窗口渲染器。
- 根据歌曲封面生成配色，并平滑过渡；导入的 Shader 可响应实时 PCM 频谱与节拍，内置 ShipSwift 预设保留原始独立动画和颜色。
- 支持 Shader 选择与导入，优化名称显示，并在重新开启背景时使用新的展示宿主。
- 增加正在播放页面 0–100% 的 Shader 透明度控制；100% 时不再保留原先整页变暗的效果。
- 在 Title／Artist、歌词与整个操作区域下方，对实时 Shader 做局部无色模糊，避免深色材质染灰；文字区域的模糊向四边逐渐消失。

### macOS 系统集成与自定义

- 提供菜单栏播放器、悬浮桌面歌词、媒体键、控制中心元数据与原生 AirPlay 输出选择。
- 增加可配置的本地与全局快捷键、原生菜单按键映射、冲突处理与快捷键录制。
- 加入配置驱动的 UI 引擎，支持组件、实时状态绑定、带参数动作、集合渲染及自定义窗口。
- 页面、主题与 keymap 可通过 `~/.config/kumone` 覆盖；文件修改后自动重载，无需重新编译。组件与示例见[配置文档](docs/config-ui.md)。

### 稳定性、验证与国际化

- 限制图片缓存和诊断日志规模，复用已保留的封面，并在生命周期结束时释放 Shader 资源与窗口持有的状态。
- 改进请求取消、过期搜索结果、分页、数据解码及 Shader 导入的原子写入。
- 增加缓存／传输生命周期、音源行为、Reducer、Hero 导航、播放布局、实际 GPU 模糊输出与原生窗口操作的测试。
- 补齐新增设置、快捷键、音源错误、播放器操作及其他界面的中英文翻译，将双语资源打包到应用目标，并检查键与格式占位符一致性。
- 将排查结论写入[经验记录](docs/lessons-learned.md)。

## 日常功能

延续 Kumone 的核心网易云体验：扫码登录、每日推荐、私人漫游、心动模式、雷达
及分类歌单、排行榜、新碟与推荐艺人、搜索、喜欢的音乐、收藏歌单／专辑／歌手、
最近播放、音乐云盘、歌单管理、同步歌词与翻译、音质选择、随机与循环、播放队列、
听歌记录，以及播放状态恢复。

## 构建与运行

主要开发目标为 **macOS 15+**，使用 **Xcode 26+** 与兼容 Swift 6.2 的工具链。
本 fork 当前以源码构建作为文档中的安装方式；上游 Homebrew 包与发行版安装的是 Kumone。

```bash
git clone --branch rewrite/appkit https://github.com/CodeEagle/kumone.git
cd kumone
swift build
Scripts/build-app.sh debug
open .build/app/MiuMiu.app
```

打包 Release 应用：

```bash
Scripts/build-app.sh release
```

默认仅构建开发机架构；打包 Universal 版本时可设置 `ARCHES="arm64 x86_64"`。
`Scripts/compile_and_run.sh debug` 可重新构建并启动本地应用。

现有更新基础设施仍指向上游 Kumone 的发行版；本分支尚未在这里提供独立的
MiuMiu 更新源、签名发行版或公证发布流程。

### Xcode 与其他 Apple 平台

根目录 XcodeGen 配置同时提供 iOS 17+ 与 visionOS 1.0+ 目标。上述详细界面
改进以 macOS 为主；提供其他平台目标不代表呈现完全一致或已经达到可发布状态。

```bash
xcodegen generate --spec project.yml
open MiuMiu.xcodeproj
```

选择 `KumoneMac`、`KumoneiOS` 或 `KumoneVision`，内部目标名称沿用现有命名。
共享 CarPlay 代码位于 `Sources/KumoneTCA/iOS/CarPlay`；旧的 `ios/` 构建配置
提供 `make configure`／`make configure-carplay` 按需启用能力。CarPlay 默认
关闭，启用需要对应的 Apple entitlement 与签名配置。

## 架构

```text
Apps/
├── Mac/                 # AppKit 应用、窗口、菜单、工具栏与系统集成
├── iOS/                 # UIKit 场景入口
├── UIKitCommon/         # UIKit 共享应用逻辑
└── Vision/              # visionOS 入口
Sources/
├── KumoneCore/          # 音源、API、模型、APlay 集成、缓存与渲染
├── KumoneTCA/           # Reducer、依赖客户端、SwiftUI 页面与 Hero 系统
├── KumoneUI/            # YAML UI 引擎、绑定、动作、主题与组件
├── KumoneShaders/       # Metal Shader、共享 Uniform 与内置预设
└── Kumone/Resources/    # 简体中文与英文翻译资源
Tests/                   # Core、TCA、UI 引擎与原生 macOS 验证
```

## 开发验证

```bash
swift test
python3 Scripts/check-localizations.py
```

国际化检查在构建后运行，以读取编译器提取的字符串。原生窗口与 Metal 检查需要
相应的 macOS 运行环境。

## 致谢与协议

MiuMiu fork 自 **missuo** 与贡献者维护的 **[Kumone](https://github.com/missuo/kumone)**。
感谢原项目提供的客户端基础，以及后续移植到本分支的改进。

- [APlay](https://github.com/CodeEagle/APlay)：播放引擎与流式缓存。
- [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture)：应用状态与副作用管理。
- ShipSwift：内置 Shader 的原始预设。
- [YesPlayMusic](https://github.com/qier222/YesPlayMusic) 与 [kaset](https://github.com/sozercan/kaset)：上游对客户端功能、设计及打包方式的参考。
- [UnblockNeteaseMusic/server](https://github.com/UnblockNeteaseMusic/server)：上游音源匹配与回退策略的参考。
- [LyricsX](https://github.com/ddddxxx/LyricsX)：上游桌面歌词的设计参考。
- [Sonimbus](https://github.com/gee1k/sonimbus)：相关的 Apple TV 网易云客户端。

保留原有 [LGPL-3.0-only](LICENSE) 协议，并随附 [GPL-3.0](COPYING) 文本。
音乐数据与版权归各平台及权利人所有。
