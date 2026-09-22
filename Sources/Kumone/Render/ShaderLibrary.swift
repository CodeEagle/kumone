import Foundation
import Metal

/// A shader the container can load.
struct ShaderDescriptor: Identifiable, Hashable {
    let id: String
    let name: String
    /// Where the MSL source came from.
    let origin: Origin

    enum Origin: Hashable {
        /// Ships inside the app bundle, compiled into `default.metallib`.
        case bundled
        /// A `.metal` file the user dropped into the shaders directory.
        case userFile(URL)
    }
}

/// Discovers shaders and compiles them into a Metal library on demand.
///
/// Two sources:
/// - Bundled shaders, compiled at build time into the framework's
///   `default.metallib` and loaded with `makeDefaultLibrary()`.
/// - User `.metal` files, read from disk and compiled at runtime with
///   `makeLibrary(source:)`. Runtime MSL compilation is supported on macOS and
///   iOS, which is what makes "drop a shader in a folder" work at all.
///
/// A compiled library is cached per descriptor so switching back to a shader is
/// instant; a failed compile is remembered as `nil` so the error isn't retried
/// sixty times a second.
@MainActor
final class ShaderLibrary: ObservableObject {
    static let shared = ShaderLibrary()

    private var cache: [ShaderDescriptor: any MTLLibrary] = [:]
    private var failures: Set<String> = []

    /// Shaders found the last time the directory was scanned. Published so a
    /// view that read the list before the first `reload()` — the bundled
    /// library is compiled into the framework's resource bundle and is empty
    /// until then — re-renders once the scan has something to show.
    @Published private(set) var available: [ShaderDescriptor] = []

    private init() {}

    // MARK: - Discovery

    /// Reloads the shader list: bundled presets plus whatever `.metal` files
    /// currently sit in the user's shaders directory.
    func reload() {
        var found = bundledShaders()
        found.append(contentsOf: userShaders())
        // Stable order: bundled first, then user files by name.
        available = found.sorted { lhs, rhs in
            if lhs.origin != rhs.origin {
                // Bundled before user files.
                if case .bundled = lhs.origin { return true }
                return false
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func bundledShaders() -> [ShaderDescriptor] {
        // The vertex stage and helpers live in the shared types header, which
        // is compiled into the default library alongside every bundled shader.
        guard let library = defaultLibrary() else { return [] }
        guard let names = try? library.functionNames else { return [] }

        return names
            .filter { $0.hasPrefix(ShaderNaming.fragmentPrefix) }
            .map { name in
                ShaderDescriptor(
                    id: "bundled.\(name)",
                    name: ShaderNaming.displayName(fragmentFunction: name),
                    origin: .bundled
                )
            }
    }

    private func userShaders() -> [ShaderDescriptor] {
        guard let directory = ShaderDirectory.url else { return [] }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return urls
            .filter { $0.pathExtension.lowercased() == "metal" }
            .map { url in
                ShaderDescriptor(
                    id: "user.\(url.lastPathComponent)",
                    name: url.deletingPathExtension().lastPathComponent,
                    origin: .userFile(url)
                )
            }
    }

    // MARK: - Compilation

    /// Returns a compiled library for the descriptor, or `nil` if the shader
    /// failed to build. The fragment function name is looked up separately by
    /// `Renderer` via `fragmentFunctionName(for:)`.
    func library(for descriptor: ShaderDescriptor) -> (any MTLLibrary)? {
        if let cached = cache[descriptor] { return cached }
        guard !failures.contains(descriptor.id) else { return nil }

        switch descriptor.origin {
        case .bundled:
            guard let library = try? defaultLibrary() else { return nil }
            cache[descriptor] = library
            return library
        case .userFile(let url):
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                failures.insert(descriptor.id)
                return nil
            }
            guard let device = MTLCreateSystemDefaultDevice() else { return nil }
            guard let library = try? device.makeLibrary(source: source, options: nil) else {
                failures.insert(descriptor.id)
                return nil
            }
            cache[descriptor] = library
            return library
        }
    }

    /// The fragment function a descriptor's library should expose.
    func fragmentFunctionName(for descriptor: ShaderDescriptor) -> String {
        switch descriptor.origin {
        case .bundled:
            return ShaderNaming.fragmentFunction(for: descriptor.name)
        case .userFile:
            // User files name their entry point themselves.
            return ShaderNaming.userFragmentFunction
        }
    }

    /// Wipes the compiled-library cache so a reloaded shader file is picked up.
    func invalidate() {
        cache.removeAll()
        failures.removeAll()
    }

    private func defaultLibrary() -> (any MTLLibrary)? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }

        // The compiled shaders live in the KumoneShaders target's own resource
        // bundle. `Bundle(for:)` returns the *host* module's bundle (the app,
        // or the xctest bundle under swift test); the shader bundle is nested
        // inside it as `Kumone_KumoneShaders.bundle`.
        for candidate in shaderBundleCandidates() {
            if let library = try? device.makeDefaultLibrary(bundle: candidate) {
                return library
            }
        }
        return try? device.makeDefaultLibrary(bundle: .main)
    }

    /// Every bundle that might contain the compiled shaders. The nested
    /// resource bundle is tried first because it is where SwiftPM actually
    /// puts `default.metallib`; the host and main bundles cover an app that
    /// embeds the shaders directly.
    private func shaderBundleCandidates() -> [Bundle] {
        let host = Bundle(for: ShaderBundleToken.self)

        var candidates: [Bundle] = []
        let suffix = "_KumoneShaders.bundle"
        for sub in host.paths(forResourcesOfType: "bundle", inDirectory: nil)
        where sub.hasSuffix(suffix) {
            if let nested = Bundle(url: URL(fileURLWithPath: sub)) {
                candidates.append(nested)
            }
        }
        candidates.append(host)
        candidates.append(.main)
        return candidates
    }
}

// MARK: - Naming

enum ShaderNaming {
    /// Prefix on every bundled fragment function, e.g. `kumone_fragment_aurora`.
    static let fragmentPrefix = "kumone_fragment_"

    /// The entry point a user-written `.metal` file must provide.
    static let userFragmentFunction = "kumone_fragment"

    /// `kumone_fragment_swirl` → `Swirl`
    static func displayName(fragmentFunction: String) -> String {
        guard fragmentFunction.hasPrefix(fragmentPrefix) else { return fragmentFunction }
        let rest = fragmentFunction.dropFirst(fragmentPrefix.count)
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }

    /// `Swirl` → `kumone_fragment_swirl`
    static func fragmentFunction(for displayName: String) -> String {
        let lower = displayName.lowercased()
        return fragmentPrefix + lower
    }
}

// MARK: - Shaders directory

enum ShaderDirectory {
    /// Where user `.metal` files are looked for. macOS reads Application Support
    /// directly; iOS is sandboxed and surfaces the same folder through Files.
    static var url: URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("Kumone/Shaders", isDirectory: true)
    }

    /// Creates the directory if it does not exist, so the first run has
    /// somewhere to drop a shader.
    static func ensureExists() {
        guard let url else { return }
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }
}

/// Marker type so `Bundle(for:)` finds the KumoneShaders resource bundle from
/// inside KumoneCore.
final class ShaderBundleToken {}
