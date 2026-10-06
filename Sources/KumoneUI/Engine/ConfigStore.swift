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
///     ~/.config/kumone/theme-<name>.yaml
///     ~/.config/kumone/keymap.yaml
///
/// Every file watcher is a DispatchSource on the directory: editing a YAML
/// in any editor rebuilds the affected screens, and SwiftUI's diffing makes
/// the swap free — nothing reloads but what the tree actually changed.
@MainActor
public final class ConfigStore: ObservableObject {
    /// One parsed screen plus its resolved theme and window geometry.
    public struct Screen: Equatable {
        public let name: String
        public let root: Node
        public let stylesheet: Stylesheet
        public let window: ConfigParser.ScreenWindow

        public init(name: String,
                    root: Node,
                    stylesheet: Stylesheet,
                    window: ConfigParser.ScreenWindow = ConfigParser.ScreenWindow()) {
            self.name = name
            self.root = root
            self.stylesheet = stylesheet
            self.window = window
        }
    }

    @Published public private(set) var screens: [String: Screen] = [:]
    @Published public private(set) var keymap: Keymap = .empty
    /// Every theme file found, by name (`theme-aurora.yaml` → `aurora`).
    /// `theme.yaml` is the nameless default and maps to `default`.
    @Published public private(set) var themes: [String: Stylesheet] = [:]
    /// Which theme screens are rendered with. Persists through
    /// `themeStorage` when one was given, so the choice survives launch.
    @Published public private(set) var currentTheme: String = "default"
    @Published public private(set) var diagnostics: [String] = []

    private let bundled: URL?
    private let user: URL?
    private let themeStorage: ThemeStorage?
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var contentsWatchers: [DispatchSourceFileSystemObject] = []

    /// - Parameters:
    ///   - bundled: The app's default screens (Resource bundle dir).
    ///   - user: The user's override directory (`nil` to disable).
    ///   - themeStorage: Persisted current theme (`nil` = forget choices
    ///     at quit; the app passes a UserDefaults-backed one).
    public init(bundled: URL?,
                user: URL?,
                themeStorage: ThemeStorage? = nil) {
        self.bundled = bundled
        self.user = user
        self.themeStorage = themeStorage
        if let stored = themeStorage?.themeName(), !stored.isEmpty {
            currentTheme = stored
        }
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
        var issues: [String] = []

        var themes: [String: Stylesheet] = [:]
        for url in themeCandidates() {
            if let parsed = loadTheme(url, issues: &issues) {
                themes[themeName(of: url)] = parsed
            }
        }
        self.themes = themes
        // A stored theme that no longer exists (the file was deleted, or a
        // name typo) falls back to default rather than an empty sheet.
        if !themes.keys.contains(currentTheme) { currentTheme = "default" }

        var loaded: [String: Screen] = [:]
        let stylesheet = themes[currentTheme] ?? themes["default"] ?? Stylesheet()
        for url in screenCandidates() {
            let name = url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: url),
                  let yaml = String(data: data, encoding: .utf8) else {
                issues.append("\(url.lastPathComponent): unreadable")
                continue
            }
            do {
                let document = try ConfigParser.screenDocument(from: yaml)
                loaded[name] = Screen(name: name,
                                      root: document.root,
                                      stylesheet: stylesheet,
                                      window: document.window)
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

    /// Switches every screen to another theme by name. Unknown names
    /// keep the current theme (a typo'd switch does nothing); the file
    /// watcher re-renders on edit, so this is the same path as a reload.
    public func setCurrentTheme(_ name: String) {
        guard themes.keys.contains(name) else { return }
        guard name != currentTheme else { return }
        currentTheme = name
        themeStorage?.setThemeName(name)
        // Re-render the screens with the new sheet: same code the reload
        // ran, without re-reading any file.
        guard let stylesheet = themes[name] else { return }
        screens = screens.mapValues {
            Screen(name: $0.name, root: $0.root, stylesheet: stylesheet, window: $0.window)
        }
    }

    // MARK: - Discovery

    private func themeCandidates() -> [URL] {
        // theme.yaml (the nameless default) and theme-<name>.yaml side by
        // side; user files replace bundled ones of the same name, since
        // later entries overwrite earlier.
        var urls: [URL] = []
        for base in [bundled, user].compactMap({ $0 }) {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: base, includingPropertiesForKeys: nil) else { continue }
            urls.append(contentsOf: contents.filter { isThemeFile($0) })
        }
        return urls
    }

    private func isThemeFile(_ url: URL) -> Bool {
        guard url.pathExtension == "yaml" else { return false }
        let stem = url.deletingPathExtension().lastPathComponent
        return stem == "theme" || stem.hasPrefix("theme-")
    }

    /// The theme's name from its file: `theme.yaml` → `default`,
    /// `theme-aurora.yaml` → `aurora`.
    private func themeName(of url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem == "theme" ? "default" : String(stem.dropFirst("theme-".count))
    }

    private func screenCandidates() -> [URL] {
        var urls: [URL] = []
        for base in [bundled, user].compactMap({ $0 }) {
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: base, includingPropertiesForKeys: nil) {
                // Themes and the keymap sit in the same directory but are
                // not screens.
                urls.append(contentsOf: contents.filter {
                    $0.pathExtension == "yaml"
                    && !isThemeFile($0)
                    && $0.lastPathComponent != "keymap.yaml"
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

/// Persists the user's chosen theme across launches. The engine stays free
/// of storage specifics (UserDefaults is an app concern); tests inject an
/// in-memory one, the app injects a real one.
public protocol ThemeStorage {
    /// The theme name to start from, or nil when none was chosen.
    func themeName() -> String?
    /// Records the new choice.
    func setThemeName(_ name: String)
}
