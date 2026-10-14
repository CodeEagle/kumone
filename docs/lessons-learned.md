# 开发经验

## 2026-10-14：hero 转场的背景必须纳入透明门控

现象：进入歌单详情时，源封面会先被背景遮住，再出现 hero 封面。

原因：歌单、专辑、歌手详情页在 `.opacity(hasAppeared ? 1 : 0)` 之后添加
`.background(.ultraThinMaterial)`，透明度只控制前面的内容，外层毛玻璃背景
在等待数据和目标布局时已经可见。正确顺序是：

```swift
.background(.ultraThinMaterial)
.opacity(hasAppeared ? 1 : 0)
.animation(AppAnimation.smooth, value: hasAppeared)
```

验证透明门控时，内容层与背景层都要独立采样。原来的测试只有内容探针，
无法发现背景绕过门控。为 `TransitionGateTests` 增加背景探针后，旧顺序下
背景 opacity 保持 1.0，push 中和结束后的检查都失败；修复顺序下通过。
`HeroNavigationTests` 与 `TransitionGateTests` 共 6 项通过。

飞行日志、内容淡入与 z 序正常，只能证明被采样的机制正常，不能排除遗漏层。
先核对修饰器顺序并做对照实验，再判断是否是旧进程。部署要关闭旧进程、
重启应用，并核对本地与远端二进制哈希及远端进程启动时间。

本次 debug 构建已部署 workmini，SHA-256 一致，新进程启动后用户确认“可以”。
保留现有退出目标门控与 spring 参数。`onGeometryChange` 不能作为逐帧呈现
进度；现有提前 release 的时序若需调整，应另行取证。

## 2026-10-14：新增功能的文案与标题布局

国际化不能只补翻译表。枚举显示名、错误信息、动态按钮标签和 AppKit 控件
使用普通 `String`，必须在生成文案的位置调用 `String(localized:)`。
歌曲名、歌手名、Shader 名称和服务地址属于数据，不作为翻译键。

中文和英文表保持相同键集，插值占位符的类型和数量必须一致。构建后运行
`python3 Scripts/check-localizations.py`，对照编译器生成的 `.stringsdata`
检查实际调用点；Xcode 目标也必须把 `.lproj` 放入资源阶段。

正在播放的标题单独对齐播放列中轴。按 tags 的实际宽度在左右各预留相同
空间，右侧 tags 紧跟标题，长标题截断；文字区随列宽变化，左右各留 24pt。
不能依靠整个 title + tags 的 HStack 居中，否则标题会向左偏移。

歌手与专辑信息需要完整显示时，不能只扩大外层 frame：原来的 HStack 和
`.lineLimit(1)` 仍会逐项截断。详情改用带导航链接的 AttributedString 自动
换行，紧凑模式保留单行；Hero 的详情端也必须使用相同的多行渲染器。

Shader 遮罩控制的是正在播放时渲染器已有的合成透明度：旧背景强度为
50% 时，暗色原生背景透过 Shader，使整页均匀变暗。不要另外叠一层黑色；
正在播放的额外 0.28 黑色渐变也会让 100% 仍然发灰，需要移除。100% 使用 Shader 原始画面；
没有保存新值时继承原背景强度，普通页面仍使用原来的背景强度设置。
0% 是有效保存值，不能当成缺省值；标题与说明同步加入中英文翻译表。

隐藏系统窗口按钮时，不能同时禁用它们，否则 AppKit 会拒绝 ⌘W。完全透明
的关闭按钮还会影响原生命令校验：KumoneWindow 在沉浸模式下允许关闭菜单，
同步派发 performClose 时暂时恢复按钮 alpha 和 enabled，仍走标准
windowShouldClose，再立即恢复视觉状态。用实际 NSWindow 委托验证命令到达。
标题／歌手、歌词及整个操作区使用局部无色背景模糊，横纵边缘渐隐。
ultraThinMaterial 在深色外观下会染灰；CALayer backgroundFilters 在此
SwiftUI／Metal 合成链路里没有实际模糊 Shader。改为在同一 Metal 帧中
生成 Gaussian 模糊，再根据原生视图的位置合成局部区域，不添加染色。
必须读取 GPU 输出验证边缘确实变软、区域外保持原色，不能只检查滤镜配置。
浅色 Shader 上白色图标需要半透明黑色按钮背景，Hero 的起止背景同步。
