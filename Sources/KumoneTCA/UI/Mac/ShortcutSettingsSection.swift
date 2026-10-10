#if os(macOS)
import AppKit
import SwiftUI

/// Local monitor routes Command chords here before native menus consume them.
public protocol ShortcutRecordingResponder: AnyObject {
    func recordShortcut(event: NSEvent)
}

struct ShortcutSettingsSection: View {
    @ObservedObject private var manager = ShortcutManager.shared
    @State private var global = false
    @State private var recording: ShortcutAction?
    var body: some View {
        Section("快捷键") {
            Picker("快捷键类型", selection: $global) {
                Text("应用内").tag(false)
                Text("全局").tag(true)
            }.pickerStyle(.segmented)
            ForEach(ShortcutAction.allCases) { action in
                HStack {
                    Text(action.displayName)
                    Spacer()
                    Button(recording == action ? "请按下按键…" : manager.shortcut(for: action, isGlobal: global).displayString) {
                        recording = action
                        manager.isRecording = true
                    }
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 110)
                    if recording == action {
                        ShortcutRecorder { shortcut in
                            manager.setShortcut(shortcut, for: action, isGlobal: global)
                            cancelRecording()
                        } cancel: { cancelRecording() }
                        .frame(width: 1, height: 1)
                    }
                }
            }
            Text(global ? "全局默认关闭。设置 ⌘、⌃ 或 ⌥ 组合后，在其他应用中也能控制播放。"
                        : "点击按键录制，Esc 清除。系统窗口快捷键保持不变。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = manager.errorMessage { Text(error).foregroundStyle(.red).font(.caption) }
            Button("重置所有快捷键") {
                cancelRecording()
                manager.resetToDefaults()
            }
        }
        .onChange(of: global) { _, _ in cancelRecording() }
        .onDisappear { cancelRecording() }
    }
    private func cancelRecording() {
        recording = nil
        manager.isRecording = false
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let record: (UserShortcut) -> Void
    let cancel: () -> Void
    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.record = record
        view.cancel = cancel
        return view
    }
    func updateNSView(_ view: RecorderView, context: Context) {
        view.record = record
        view.cancel = cancel
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window, window.firstResponder !== view else { return }
            window.makeFirstResponder(view)
        }
    }
    static func dismantleNSView(_ view: RecorderView, coordinator: ()) {
        view.record = nil
        view.cancel = nil
    }
    final class RecorderView: NSView, ShortcutRecordingResponder {
        var record: ((UserShortcut) -> Void)?
        var cancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        func recordShortcut(event: NSEvent) { keyDown(with: event) }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { record?(.init(key: "", modifiers: [])); return }
            guard let key = event.charactersIgnoringModifiers, key.count == 1 else { return }
            record?(.init(key: key, modifiers: .init(event.modifierFlags), keyCode: UInt32(event.keyCode)))
        }
        override func resignFirstResponder() -> Bool {
            cancel?()
            return super.resignFirstResponder()
        }
    }
}
#endif
