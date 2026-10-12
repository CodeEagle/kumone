import AppKit
import Combine
import ComposableArchitecture
import KumoneCore
import KumoneTCA
import KumoneUI
import Observation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store(initialState: AppFeature.State()) {
        AppFeature()
    } withDependencies: {
        $0.playback = PlaybackEngineAdapter.client
        $0.updater = UpdaterAdapter.client
        $0.pasteboard = PasteboardAdapter.client
    }
    private let artworkStore = NowPlayingArtworkStore()
    private var cancellables = Set<AnyCancellable>()
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var menuBarPlayer: MenuBarPlayerController?
    private var keymapMonitor: AppKeymapMonitor?
    private var configStore: ConfigStore?
    private var screenWindows: [String: ConfigPreviewWindow] = [:]
    /// Drops a preview window from `screenWindows` when it closes. Without it,
    /// a closed screen pins its hosting controller and SwiftUI tree until the
    /// app quits — reopening the screen builds a fresh window anyway.
    private var screenCloseObserver: NSObjectProtocol?
    private var debugPushObserver: NSObjectProtocol?
    private lazy var actions: ActionRegistry = {
        let registry = AppActions.dispatcher(store: store)
        // Window-level verbs are registered here, not in AppActions: they
        // need this object's window plumbing, not the store.
        registry.register("app.presentScreen") { [weak self] argument in
            guard case .string(let name) = argument else { return }
            self?.presentScreen(name)
        }
        // The theme switch: one verb, one string argument — a ForEach over
        // app.themeNames with `argument: ${item}` makes the buttons.
        registry.register("app.setTheme") { [weak self] argument in
            guard case .string(let name) = argument else { return }
            self?.configStore?.setCurrentTheme(name)
        }
        return registry
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance(store.settings.appearance.brightnessIntent.colorScheme)
        // The keymap replaces what used to be a hard-coded space/esc handler:
        // the same shortcuts now live in keymap.yaml and a user can rebind
        // them (or remove them) without touching Swift.
        loadConfigStore()
        keymapMonitor = AppKeymapMonitor(store: configStore!, dispatcher: actions)
        keymapMonitor?.start()
        GlobalHotKeyManager.shared.start { [weak self] action in
            _ = self?.actions.invoke(action.actionName)
        }

        ShaderDiscovery.shared.reload()
        store.send(.setShader(resolveInitialShaderID()))
        // Register the config-driven UI components: layout primitives, Text,
        // Container, SpectrumBars. Screens reference them by `type` name in
        // their YAML; the registry is the same channel plugins would use.
        BuiltinComponents.register()
        showMainWindow()

        // Diagnostics hook: posting `kumoneDebugPushDetail` drives one
        // detail-page push from outside (lldb, scripts), so the push
        // transition can be captured frame by frame without GUI automation.
        debugPushObserver = NotificationCenter.default.addObserver(
            forName: .kumoneDebugPushDetail, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // withAnimation to match the real tap path, so the push
                // transition this hook drives resembles a user's
                // (AppAnimation.smooth is module-internal; same curve).
                withAnimation(.easeInOut(duration: 0.35)) {
                    self?.store.send(.openDestination(.playlist(3136952023)))
                }
            }
        }

        #if DEBUG
        // Zero-human hero verification: with KUMONE_HERO_SELF_TEST=1 the app
        // runs one now-playing round trip, logs the verdict, and quits, so a
        // script can assert the transition without a GUI.
        if HeroSelfTest.isEnabled {
            Task { await HeroSelfTest.run(appStore: store) }
        }
        // Memory-leak reproduction without a GUI: KUMONE_LEAK_STRESS=1 plays
        // through a playlist and skips every few seconds while sampling the
        // resident footprint, writing /tmp/kumone-leak.log.
        if LeakStress.isEnabled {
            Task { await LeakStress.run(appStore: store) }
        }
        #endif
        artworkStore.update(
            trackID: store.player.currentTrack?.id,
            artworkURL: store.player.currentTrack?.album.picUrl
        )
        observeArtwork()
        observeArtworkColors()
        applyShader()
        observeShader()
        observeShaderSettings()
        syncDesktopLyrics()
        observeAppearance()
        observeDesktopLyrics()
        MainMenu.install(store: store, showSettings: { [weak self] in self?.showSettings() })
        ShortcutManager.shared.$appShortcuts
            .receive(on: DispatchQueue.main)
            .sink { _ in MainMenu.refreshPlaybackShortcuts() }
            .store(in: &cancellables)
        menuBarPlayer = MenuBarPlayerController(store: store) { [weak self] in
            guard let self else { return }
            if let controller = self.mainWindowController {
                controller.showWindow(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
            } else {
                self.showMainWindow()
            }
        }
        if let window = mainWindowController?.window {
            HeroVisualAcceptance.start(appStore: store, window: window)
        }
        screenCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let window = note.object as? ConfigPreviewWindow else { return }
                self.screenWindows = self.screenWindows.filter { $0.value !== window }
            }
        }
        presentScreen("preview")
    }

    /// The config root: bundled defaults overridable by the user's
    /// `~/.config/kumone/screens` directory. App-level (not per window) so
    /// the keymap and the preview screens share one watcher.
    private func loadConfigStore() {
        guard configStore == nil else { return }
        // SwiftPM compiles the target's Resources/ directory into
        // Kumone_KumoneUI.bundle/Contents/Resources/Resources/screens/.
        let bundled = Bundle(for: KumoneUIBundleMarker.self)
            .resourceURL?.appendingPathComponent("Resources").appendingPathComponent("screens")
        let user = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/kumone/screens")
        configStore = ConfigStore(
            bundled: bundled, user: user, themeStorage: UserDefaultsThemeStorage())
    }

    private func applyAppearance(_ scheme: ColorScheme?) {
        switch scheme {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil // follow system
        }
    }

    private func observeAppearance() {
        withObservationTracking { [weak self] in
            _ = self?.store.settings.appearance.brightnessIntent.colorScheme
        } onChange: { [weak self] in
            // Observation fires before mutation; defer reads and rearm its one-shot tracking.
            DispatchQueue.main.async { [weak self] in
                self?.applyAppearance(self?.store.settings.appearance.brightnessIntent.colorScheme)
                self?.observeAppearance()
            }
        }
    }

    private func syncDesktopLyrics() {
        DesktopLyricsController.shared.sync(with: store.settings.showDesktopLyrics, store: store)
    }

    private func observeDesktopLyrics() {
        withObservationTracking { [weak self] in
            _ = self?.store.settings.showDesktopLyrics
        } onChange: { [weak self] in
            // Observation fires before mutation; defer reads and rearm its one-shot tracking.
            DispatchQueue.main.async {
                self?.syncDesktopLyrics()
                self?.observeDesktopLyrics()
            }
        }
    }

    private func applyShader() {
        guard let container = mainWindowController?.window?.contentViewController as? MainContainerViewController else {
            return
        }
        // The old "主界面环境色" switch now gates the window-level shader: off
        // means the frosted backdrop below it is the whole background.
        let descriptor: ShaderDescriptor?
        if store.settings.showMainWindowAmbientBackground {
            descriptor = store.shaderID.flatMap { id in
                ShaderDiscovery.shared.availableDescriptors.first { $0.id == id }
            }
        } else {
            descriptor = nil
        }
        // This store only supplies the shader's palette. Disabling the shader
        // cancels its request and releases its cover, independently of metadata.
        artworkStore.setArtworkNeeded(false)
        // The intensity slider scales how strongly the shader composites over
        // the frosted backdrop, keeping the old "背景色强度" control meaningful.
        let intensity = store.settings.mainWindowAmbientBackgroundIntensity
        KumoneLogger.app.notice("SHADER WINDOW requested=\(self.store.shaderID ?? "nil", privacy: .public) enabled=\(self.store.settings.showMainWindowAmbientBackground) intensity=\(intensity) resolved=\(descriptor?.id ?? "nil", privacy: .public)")
        container.shaderLayer.layer?.opacity = Float(min(max(intensity, 0), 1))
        container.shaderLayer.apply(
            // MainWindow now owns the single visible renderer. Keep the old
            // native shell inert rather than running a duplicate behind it.
            shader: nil,
            isPlaying: store.player.isPlaying,
            palette: ShaderPaletteBuilder.make(from: artworkStore.colors),
            pcmSync: ShaderSettings.shared.pcmSyncEnabled
        )
        container.logShaderStack(shaderID: descriptor?.id)
    }

    /// Restores the user's last pick instead of always landing on the first
    /// bundled shader: a "no shader" pick stays off, and a named pick resolves
    /// to its descriptor. Falls back to the first shader when the stored name
    /// is gone (deleted import) or nothing was ever picked.
    private func resolveInitialShaderID() -> String? {
        let settings = ShaderSettings.shared
        if settings.shaderPickingDisabled { return nil }
        let name = settings.pickedShaderName
        if !name.isEmpty,
           let match = ShaderDiscovery.shared.availableDescriptors.first(where: { $0.name == name }) {
            return match.id
        }
        return ShaderDiscovery.shared.availableDescriptors.first?.id
    }

    /// The window backdrop is a shader too, so it has to follow the same
    /// PCM-sync switch the shader list exposes.
    private func observeShaderSettings() {
        ShaderSettings.shared.$pcmSyncEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyShader()
            }
            .store(in: &cancellables)
        // Every picker writes the shared selection. Keep the native window in
        // sync too, rather than relying on a particular SwiftUI surface to
        // forward an action. Defer reads until both name/disabled writes finish.
        ShaderSettings.shared.$pickedShaderName
            .combineLatest(ShaderSettings.shared.$shaderPickingDisabled)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let id = self.resolveInitialShaderID()
                guard self.store.shaderID != id else { return }
                self.store.send(.setShader(id))
                self.applyShader()
            }
            .store(in: &cancellables)
    }

    private func observeArtwork() {
        withObservationTracking { [weak self] in
            _ = self?.store.player.currentTrack?.id
            _ = self?.store.player.currentTrack?.album.picUrl
        } onChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.artworkStore.update(
                    trackID: self.store.player.currentTrack?.id,
                    artworkURL: self.store.player.currentTrack?.album.picUrl
                )
                self.applyShader()
                self.observeArtwork()
            }
        }
    }

    private func observeArtworkColors() {
        ImageLoadingControl.shared.$isDisabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyShader() }
            .store(in: &cancellables)
        artworkStore.$colors
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyShader()
            }
            .store(in: &cancellables)
    }

    private func observeShader() {
        withObservationTracking { [weak self] in
            _ = self?.store.shaderID
            _ = self?.store.settings.disableImageLoading
            _ = self?.store.player.isPlaying
            _ = self?.store.settings.showMainWindowAmbientBackground
            _ = self?.store.settings.mainWindowAmbientBackgroundIntensity
        } onChange: { [weak self] in
            // Observation fires before mutation; defer reads and rearm its one-shot tracking.
            DispatchQueue.main.async {
                self?.applyShader()
                self?.observeShader()
            }
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        DockMenu().makeMenu(from: store.player) { action in
            switch action {
            case .togglePlayPause: self.store.send(.player(.togglePlayPause))
            case .next: self.store.send(.player(.next))
            case .previous: self.store.send(.player(.previous))
            case .toggleShuffle: self.store.send(.player(.toggleShuffle))
            case let .setRepeatMode(mode): self.store.send(.player(.setRepeatMode(mode)))
            case let .playContext(context): self.store.send(.player(.playContext(context)))
            default: break
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        // `hasVisibleWindows` is unreliable here: helper windows such as the
        // desktop-lyrics overlay make it `true` even when the main window is
        // gone, so decide based on the main window itself.
        //
        // The native shell keeps the main window alive on close (it is ordered
        // out rather than destroyed), so it is normally still around — just
        // hidden and/or miniaturised, and possibly behind other windows.
        // Restore and front it. Only if it truly no longer exists do we build
        // a fresh window.
        let target = mainWindowController?.window ?? sender.windows.first {
            $0.styleMask.contains(.titled) && $0.canBecomeMain
        }
        if let window = target {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            showMainWindow()
        }
        // Fully handled above; returning `false` prevents AppKit from also
        // enqueuing its own re-open handling.
        return false
    }

    /// Opens the settings window.
    @objc func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(store: store)
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens a screen by name as its own preview window, or focuses it if
    /// that screen is already open. Any YAML in the screens directory is a
    /// screen: drop `fancy.yaml` in `~/.config/kumone/screens`, open it with
    /// a button (`action: app.presentScreen`, `argument: fancy`) or from a
    /// keymap once one can carry arguments.
    func presentScreen(_ name: String) {
        if let window = screenWindows[name] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let config = configStore else { return }
        guard let screen = config.screens[name] else {
            #if DEBUG
            print("[Kumone] no screen named: \(name)")
            #endif
            return
        }
        let resolver = AppBindingResolver(store: store, configStore: config)
        let window = ConfigPreviewWindow(
            screen: name, screenWindow: screen.window,
            configStore: config, resolver: resolver, dispatcher: actions)
        screenWindows[name] = window
        window.makeKeyAndOrderFront(nil)
    }
}

/// Marker to resolve the KumoneUI resource bundle (screens/*.yaml are
/// compiled into that target's Resources).
final class KumoneUIBundleMarker {}

extension AppDelegate {
    func showMainWindow() {
        let controller = MainWindowController(store: store)
        mainWindowController = controller
        controller.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKeyManager.shared.shutdown()
        keymapMonitor?.stop()
    }
}

/// Theme choice on disk: UserDefaults, one string. The engine only knows
/// the `ThemeStorage` protocol; the key is an app detail.
private struct UserDefaultsThemeStorage: ThemeStorage {
    private let key = "kumone.config.themeName"

    func themeName() -> String? {
        let name = UserDefaults.standard.string(forKey: key)
        return name?.isEmpty == false ? name : nil
    }

    func setThemeName(_ name: String) {
        UserDefaults.standard.set(name, forKey: key)
    }
}
