import ComposableArchitecture
import KumoneCore
import SwiftUI

public struct SettingsView: View {
    public init(store: StoreOf<SettingsFeature>, appStore: StoreOf<AppFeature>) {
        self.store = store
        self.appStore = appStore
    }

    // `@SwiftUI.Bindable` (qualified): an unqualified `@Bindable` is ambiguous
    // between SwiftUI's wrapper and Perception's backport in this module.
    @SwiftUI.Bindable var store: StoreOf<SettingsFeature>
    let appStore: StoreOf<AppFeature>

    @AppStorage("lx.baseURL") private var lxBaseURL = ""
    @AppStorage("lx.apiKey") private var lxAPIKey = ""
    @AppStorage("lx.platform") private var lxPlatform = "wy"

    @State private var cacheSize: String = String(localized: "计算中…")

    public var body: some View {
        Form {
            Section("播放") {
                Picker("音质", selection: Binding(
                    get: { store.audioQuality },
                    set: { store.send(.setAudioQuality($0)) }
                )) {
                    ForEach(AudioQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                Text("无损与 Hi-Res 需要黑胶 VIP，未开通时自动回落到可用音质")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("灰色歌曲解锁", isOn: Binding(
                    get: { store.enableUnblock },
                    set: { store.send(.setEnableUnblock($0)) }
                ))
                Text("无版权 / 下架歌曲自动从第三方音源（酷我、酷狗等）匹配播放")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("外观") {
                Picker("主题", selection: Binding(
                    get: { store.appearance },
                    set: { store.send(.setAppearance($0)) }
                )) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                Picker("播放页模式", selection: Binding(
                    get: { store.nowPlayingMode },
                    set: { store.send(.setNowPlayingMode($0)) }
                )) {
                    ForEach(NowPlayingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Toggle("显示歌词翻译", isOn: Binding(
                    get: { store.showLyricsTranslation },
                    set: { store.send(.setShowLyricsTranslation($0)) }
                ))
                Toggle("逐字歌词（卡拉OK）", isOn: Binding(
                    get: { store.verbatimLyrics },
                    set: { store.send(.setVerbatimLyrics($0)) }
                ))
                Picker("日文歌词读音", selection: Binding(
                    get: { store.lyricsAnnotation },
                    set: { store.send(.setLyricsAnnotation($0)) }
                )) {
                    ForEach(LyricsAnnotation.allCases) { annotation in
                        Text(annotation.displayName).tag(annotation)
                    }
                }
                Text("罗马音在歌词上方另起一行，汉字读音把假名标在汉字正上方；缺少官方罗马音时自动生成读音")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("主界面环境色", isOn: Binding(
                    get: { store.showMainWindowAmbientBackground },
                    set: { store.send(.setShowMainWindowAmbientBackground($0)) }
                ))
                if store.showMainWindowAmbientBackground {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("背景色强度")
                            Spacer()
                            Text("\(Int(store.mainWindowAmbientBackgroundIntensity * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { store.mainWindowAmbientBackgroundIntensity },
                                set: { store.send(.setMainWindowAmbientBackgroundIntensity($0)) }
                            ),
                            in: SettingsFeature.intensityRange,
                            step: 0.1
                        )
                        HStack {
                            Text("50%")
                            Spacer()
                            Text("150%")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                #if os(macOS)
                Toggle("桌面歌词", isOn: Binding(
                    get: { store.showDesktopLyrics },
                    set: { store.send(.setShowDesktopLyrics($0)) }
                ))
                if store.showDesktopLyrics {
                    Toggle("桌面歌词水平居中", isOn: Binding(
                        get: { store.desktopLyricsCentered },
                        set: { store.send(.setDesktopLyricsCentered($0)) }
                    ))
                }
                Text("在屏幕上悬浮显示当前歌词，可拖动调整位置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }

            Section("LX 自部署解析源") {
                TextField("服务地址", text: $lxBaseURL)
                SecureField("API Key", text: $lxAPIKey)
                Picker("LX 歌曲默认平台", selection: $lxPlatform) {
                    Text("网易云 (wy)").tag("wy")
                    Text("咪咕 (mg)").tag("mg")
                    Text("酷狗 (kg)").tag("kg")
                    Text("酷我 (kw)").tag("kw")
                    Text("QQ (tx)").tag("tx")
                }
                Text("填写自行部署的 LX-Source 服务地址；仅提供链接和歌词解析。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("存储") {
                LabeledContent("图片缓存", value: cacheSize)
                Button("清除缓存") {
                    clearCache()
                }
            }

            Section("账号") {
                if let profile = appStore.account.profile {
                    LabeledContent("当前账号", value: profile.nickname)
                    Button("退出登录", role: .destructive) {
                        appStore.send(.account(.logout))
                    }
                } else {
                    Text("未登录")
                        .foregroundStyle(.secondary)
                }
            }

            Section("更新") {
                Toggle("启动时自动检查更新", isOn: Binding(
                    get: { store.autoCheckUpdates },
                    set: { store.send(.setAutoCheckUpdates($0)) }
                ))
                Text("关闭后启动不再自动弹出更新提示，仍可手动检查更新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("关于") {
                LabeledContent(appDisplayName, value: appVersion)
                LabeledContent("构建") {
                    // Selectable so a build can be quoted verbatim — the build
                    // number on its own never changes here, so the commit is
                    // what actually identifies what is installed.
                    Text(buildDescription)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                #if os(iOS)
                Button {
                    IOSUpdater.shared.check(interactive: true)
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
                Text("装有 TrollStore（巨魔）可在应用内一键自动安装；否则可下载 IPA 用侧载工具重装（登录状态与设置保留）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
                Text("网易云音乐第三方客户端 · 数据来自网易云音乐")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 440, height: 480)
        #endif
        .task { updateCacheSize() }
    }

    /// The name the bundle ships under, so a build deployed as Miumiu does not
    /// report itself as Kumone here.
    private var appDisplayName: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? "Kumone"
    }

    /// Marketing version with the build number in brackets, e.g. `0.1.0 (1)`.
    /// The build number is what tells two installs of the same marketing
    /// version apart.
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else {
            return short
        }
        return "\(short) (\(build))"
    }

    /// The commit and UTC build time stamped into Info.plist by
    /// `Scripts/build-app.sh`: `40052f3 · 2026-09-29T08:44Z`. Both keys are
    /// absent when running outside a built bundle (swift run, tests), which is
    /// why each falls back on its own.
    private var buildDescription: String {
        let info = Bundle.main.infoDictionary
        let commit = info?["KumoneGitCommit"] as? String
        let date = info?["KumoneBuildDate"] as? String
        switch (commit, date) {
        case let (commit?, date?): return "\(commit) · \(date)"
        case let (commit?, nil): return commit
        case let (nil, date?): return date
        default: return "dev"
        }
    }

    private var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("im.missuo.Kumone/images", isDirectory: true)
    }

    private func updateCacheSize() {
        let dir = cacheDirectory
        DispatchQueue.global(qos: .utility).async {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey]
            )) ?? []
            let bytes = files.reduce(0) { sum, url in
                sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            let formatted = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            DispatchQueue.main.async {
                cacheSize = formatted
            }
        }
    }

    private func clearCache() {
        let dir = cacheDirectory
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            DispatchQueue.main.async {
                cacheSize = String(localized: "0 字节")
                appStore.send(.toasts(.presented(String(localized: "缓存已清除"))))
            }
        }
    }
}
