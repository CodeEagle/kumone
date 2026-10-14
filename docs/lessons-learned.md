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
