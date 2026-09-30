import AppKit
import Combine
import ComposableArchitecture
import KumoneCore
import KumoneTCA
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
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance(store.settings.appearance.brightnessIntent.colorScheme)
        // Space toggles play/pause unless a text field is being edited.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let noModifiers = event.modifierFlags
                .intersection([.command, .option, .control, .shift]).isEmpty
            let editingText = NSApp.keyWindow?.firstResponder is NSText
                || NSApp.keyWindow?.firstResponder is NSTextView

            // Space: play/pause (unless typing)
            if event.keyCode == 49, noModifiers, !editingText {
                self.store.send(.player(.togglePlayPause))
                return nil
            }
            // Esc: close the immersive now-playing page
            if event.keyCode == 53, noModifiers, self.store.isNowPlayingPresented {
                self.store.send(.dismissNowPlaying)
                return nil
            }
            return event
        }

        ShaderDiscovery.shared.reload()
        store.send(.setShader(resolveInitialShaderID()))
        showMainWindow()

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
        artworkStore.setArtworkNeeded(true)
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
        // The intensity slider scales how strongly the shader composites over
        // the frosted backdrop, keeping the old "背景色强度" control meaningful.
        let intensity = store.settings.mainWindowAmbientBackgroundIntensity
        container.shaderLayer.layer?.opacity = Float(min(max(intensity, 0), 1))
        container.shaderLayer.apply(
            shader: descriptor,
            isPlaying: store.player.isPlaying,
            palette: ShaderPaletteBuilder.make(from: artworkStore.colors),
            pcmSync: ShaderSettings.shared.pcmSyncEnabled
        )
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

    func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(store: store)
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showMainWindow() {
        let controller = MainWindowController(store: store)
        mainWindowController = controller
        controller.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
