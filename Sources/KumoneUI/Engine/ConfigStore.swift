import Foundation
import Combine
#if canImport(Darwin)
import Darwin
#endif

/// Loads screens/themes/keymaps from disk and reloads them when the files
/// change.
///
/// Two sources, one precedence: the app bundles defaults so a fresh install
/// works with no user files, and a user directory overrides them per screen
/// name. The user directory is the dotfile-style root:
///
///     ~/.config/kumone/screens/*.yaml
///     ~/.config/kumone/theme.yaml
///     ~/.config/kumone/keymap.yaml
///
/// Every file watcher is a DispatchSource on the directory: editing a YAML
/// in any editor rebuilds the affected screens, and SwiftUI's diffing makes
/// the swap free — nothing reloads but what the tree actually changed.
@MainActor
public final class ConfigStore: ObservableObject {
    /// One parsed screen plus its resolved theme.
    public struct Screen: Equatable {
        public let name: String
        public let root: Node
        public let stylesheet: Stylesheet
    }

    @Published public private(set) var screens: [String: Screen] = [:]
    @Published public private(set) var keymap: Keymap = .empty
    @Published public private(set) var diagnostics: [String] = []

    private let bundled: URL?
    private let user: URL?
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var contentsWatchers: [DispatchSourceFileSystemObject] = []

    /// - Parameters:
    ///   - bundled: The app's default screens (Resource bundle dir).
    ///   - user: The user's override directory (`nil` to disable).
    public init(bundled: URL?, user: URL?) {
        self.bundled = bundled
        self.user = user
        reload()
        startWatching()
    }

    deinit {
        for watcher in watchers { watcher.cancel() }
        for watcher in contentsWatchers { watcher.cancel() }
    }

    /// Re-reads everything. Called on startup and on file changes; safe to
    /// call anytime since failures land in `diagnostics` instead of throwing.
    public func reload() {
        var loaded: [String: Screen] = [:]
        var issues: [String] = []

        var theme = Stylesheet()
        for url in themeCandidates() {
            if let parsed = loadTheme(url, issues: &issues) { theme = parsed }
        }
        for url in screenCandidates() {
            let name = url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: url),
                  let yaml = String(data: data, encoding: .utf8) else {
                issues.append("\(url.lastPathComponent): unreadable")
                continue
            }
            do {
                loaded[name] = Screen(name: name,
                                      root: try ConfigParser.screen(from: yaml),
                                      stylesheet: theme)
            } catch {
                issues.append("\(url.lastPathComponent): \(error)")
            }
        }
        var keymap = Keymap.empty
        for url in keymapCandidates() {
            if let parsed = loadKeymap(url, issues: &issues) { keymap = parsed }
        }
        screens = loaded
        self.keymap = keymap
        diagnostics = issues
    }

    // MARK: - Discovery

    private func themeCandidates() -> [URL] {
        var urls: [URL] = []
        if let bundled { urls.append(bundled.appendingPathComponent("theme.yaml")) }
        if let user { urls.append(user.appendingPathComponent("theme.yaml")) }
        return urls
    }

    private func screenCandidates() -> [URL] {
        let nonScreens: Set<String> = ["theme.yaml", "keymap.yaml"]
        var urls: [URL] = []
        for base in [bundled, user].compactMap({ $0 }) {
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: base, includingPropertiesForKeys: nil) {
                // The theme and keymap sit in the same directory but are not
                // screens.
                urls.append(contentsOf: contents.filter {
                    $0.pathExtension == "yaml" && !nonScreens.contains($0.lastPathComponent)
                })
            }
        }
        // User files win on name collisions: later entries replace earlier.
        return urls
    }

    private func keymapCandidates() -> [URL] {
        var urls: [URL] = []
        if let bundled { urls.append(bundled.appendingPathComponent("keymap.yaml")) }
        if let user { urls.append(user.appendingPathComponent("keymap.yaml")) }
        return urls
    }

    private func loadKeymap(_ url: URL, issues: inout [String]) -> Keymap? {
        guard let data = try? Data(contentsOf: url),
              let yaml = String(data: data, encoding: .utf8) else { return nil }
        // Row-level problems land in issues through the parser; the store
        // reports them, it never throws on a shortcut it cannot read.
        return Keymap.parse(yaml, issues: &issues)
    }

    private func loadTheme(_ url: URL, issues: inout [String]) -> Stylesheet? {
        guard let data = try? Data(contentsOf: url),
              let yaml = String(data: data, encoding: .utf8) else { return nil }
        do { return try ConfigParser.theme(from: yaml) }
        catch { issues.append("\(url.lastPathComponent): \(error)"); return nil }
    }

    // MARK: - File watching

    private func startWatching() {
        #if canImport(Darwin)
        for directory in [bundled, user].compactMap({ $0 }) {
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            // Directory-level watcher: macOS sends a rename/remove event for
            // swaps and edits that the file-level watcher below would miss.
            if let source = watch(directory) { watchers.append(source) }
            if let contents = watchContents(directory) { contentsWatchers.append(contents) }
        }
        #endif
    }

    #if canImport(Darwin)
    private func watch(_ directory: URL) -> DispatchSourceFileSystemObject? {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.rename, .delete],
            queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
    #endif

    #if canImport(Darwin)
    private func watchContents(_ directory: URL) -> DispatchSourceFileSystemObject? {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
    #endif

    /// Coalesces the burst of events an editor emits on save (atomic writes
    /// fire several). One reload at the end of the burst.
    private var pending = false
    private func scheduleReload() {
        guard !pending else { return }
        pending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            pending = false
            reload()
        }
    }
}
