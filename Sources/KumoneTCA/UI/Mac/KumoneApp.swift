import ComposableArchitecture
import KumoneCore
import SwiftUI

#if os(macOS)
public struct KumoneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var store: StoreOf<AppFeature> { appDelegate.store }

    public init() {
    }

    public var body: some Scene {
        Window("MiuMiu", id: "main") {
            MainWindow(store: store)
                .tint(Theme.accent)
                .preferredColorScheme(store.settings.appearance.brightnessIntent.colorScheme)
                .frame(
                    minWidth: store.isNowPlayingPresented
                        ? Theme.Layout.minWindowWidthSidebarCollapsed
                        : Theme.Layout.minWindowWidth,
                    minHeight: Theme.Layout.minWindowHeight)
        }
        .defaultSize(width: Theme.Layout.defaultWindowWidth,
                     height: Theme.Layout.defaultWindowHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { store.send(.settings(.checkForUpdates)) }
            }

            CommandMenu("播放") {
                let player = store.player
                Button(player.isPlaying ? String(localized: "暂停") : String(localized: "播放")) {
                    store.send(.player(.togglePlayPause))
                }
                .disabled(!player.hasCurrentTrack)

                Button("下一首") { store.send(.player(.next)) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("上一首") { store.send(.player(.previous)) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)

                Divider()

                Button("随机播放") { store.send(.player(.toggleShuffle)) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("循环模式") { store.send(.player(.cycleRepeatMode)) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                SleepTimerMenu(store: store.scope(state: \.player, action: \.player))

                Divider()

                let liked = player.currentTrack.map { store.account.isLiked($0.id) } ?? false
                Button(liked ? String(localized: "取消喜欢") : String(localized: "喜欢")) {
                    if let trackID = player.currentTrack?.id {
                        store.send(.account(.toggleLike(trackID)))
                    }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!player.hasCurrentTrack)

                Button("歌词") { store.send(.player(.togglePanel(.lyrics))) }
                    .keyboardShortcut("l", modifiers: .command)

                Button("播放队列") { store.send(.player(.togglePanel(.queue))) }
                    .keyboardShortcut("u", modifiers: .command)
            }
        }

        Settings {
            SettingsView(
                store: store.scope(state: \.settings, action: \.settings),
                appStore: store
            )
                .tint(Theme.accent)
                .preferredColorScheme(store.settings.appearance.brightnessIntent.colorScheme)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let store = Store(initialState: AppFeature.State()) {
        AppFeature()
    } withDependencies: {
        $0.playback = PlaybackEngineAdapter.client
        $0.updater = UpdaterAdapter.client
        $0.pasteboard = PasteboardAdapter.client
    }

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
    }

    func applyAppearance(_ scheme: ColorScheme?) {
        switch scheme {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil // follow system
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
#endif
