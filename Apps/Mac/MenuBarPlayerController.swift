import AppKit
import ComposableArchitecture
import KumoneTCA
import Observation

/// A single status item with directly clickable controls, not a popup menu.
/// No artwork, timers, playback-progress observation or additional player.
@MainActor
final class MenuBarPlayerController: NSObject {
    private let store: StoreOf<AppFeature>
    private let showWindow: () -> Void
    private var statusItem: NSStatusItem?
    private var controls: [NSButton] = []

    init(store: StoreOf<AppFeature>, showWindow: @escaping () -> Void) {
        self.store = store
        self.showWindow = showWindow
        super.init()
        observe()
    }

    private func observe() {
        withObservationTracking {
            let visible = store.settings.showMenuBarPlayer
            let track = store.player.currentTrack
            let playing = store.player.isPlaying
            let fm = store.player.isFMMode
            let liked = track.map { store.account.isLiked($0.id) } ?? false
            update(visible: visible, title: track.map { "\($0.name) - \($0.artistNames)" },
                   playing: playing, fm: fm, liked: liked)
        } onChange: { [weak self] in
            // Observation notifies before mutation. Weak deferred rearm avoids
            // retaining this owner and reads the completed state transaction.
            DispatchQueue.main.async { [weak self] in self?.observe() }
        }
    }

    private func update(visible: Bool, title: String?, playing: Bool, fm: Bool, liked: Bool) {
        guard visible else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            controls.removeAll()
            return
        }
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        guard let host = statusItem?.button else { return }
        controls.forEach { $0.removeFromSuperview() }
        controls.removeAll()
        let hasTrack = title != nil
        let info = NSButton(title: title ?? "未在播放", target: self, action: #selector(openWindow))
        info.isBordered = false
        info.font = .menuBarFont(ofSize: 12)
        info.lineBreakMode = .byTruncatingTail
        info.toolTip = title ?? "打开 MiuMiu"
        info.setAccessibilityLabel(title ?? "打开 MiuMiu")
        host.addSubview(info)
        controls.append(info)

        addSymbol(fm ? "trash" : "backward.fill", label: fm ? "不喜欢" : "上一曲",
                  action: #selector(previousOrTrash), enabled: hasTrack, host: host)
        addSymbol(playing ? "pause.fill" : "play.fill", label: playing ? "暂停" : "播放",
                  action: #selector(togglePlayback), enabled: hasTrack, host: host)
        addSymbol("forward.fill", label: "下一曲", action: #selector(next),
                  enabled: hasTrack, host: host)
        addSymbol(liked ? "heart.fill" : "heart", label: liked ? "取消收藏" : "收藏",
                  action: #selector(toggleLike), enabled: hasTrack, host: host)

        let height = NSStatusBar.system.thickness
        var x: CGFloat = 3
        for button in controls {
            let width: CGFloat = button === info
                ? min(220, max(60, info.intrinsicContentSize.width + 8)) : 25
            button.frame = NSRect(x: x, y: 0, width: width, height: height)
            x += width
        }
        statusItem?.length = x + 3
        host.toolTip = title
    }

    private func addSymbol(_ name: String, label: String, action: Selector,
                           enabled: Bool, host: NSView) {
        let button = NSButton(image: NSImage(systemSymbolName: name, accessibilityDescription: label)!,
                              target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.isEnabled = enabled
        button.toolTip = label
        button.setAccessibilityLabel(label)
        host.addSubview(button)
        controls.append(button)
    }

    @objc private func previousOrTrash() {
        store.send(.player(store.player.isFMMode ? .fmTrash : .previous))
    }
    @objc private func togglePlayback() { store.send(.player(.togglePlayPause)) }
    @objc private func next() { store.send(.player(.next)) }
    @objc private func toggleLike() {
        if let id = store.player.currentTrack?.id { store.send(.account(.toggleLike(id))) }
    }
    @objc private func openWindow() { showWindow() }
}
