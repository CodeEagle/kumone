// A throwaway shot tool: renders the bundled screens against injected fake
// playback data and writes PNGs, so the config-driven surfaces can be
// eyeballed without a running player.
import AppKit
import Foundation
import KumoneUI
import SwiftUI

@MainActor
@main
struct ConfigShots {
    static func main() {
        let app = NSApplication.shared
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/KumoneUI/Resources/screens")
        // The engine has no component list until the host registers them;
        // without this every node is an unknown type and renders nothing.
        BuiltinComponents.register()
        let store = ConfigStore(bundled: dir, user: nil)

        // Fake but plausible playback: a track mid-song, lyrics at line 7,
        // six upcoming tracks, two covers generated locally as files so
        // AsyncImage has something real to load.
        let shotsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumone-shots", isDirectory: true)
        try? FileManager.default.removeItem(at: shotsDir)
        try? FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        let coverA = makeCover(at: shotsDir.appendingPathComponent("coverA.png"),
                               top: #colorLiteral(red: 0.91, green: 0.34, blue: 0.48, alpha: 1),
                               bottom: #colorLiteral(red: 0.16, green: 0.17, blue: 0.24, alpha: 1))
        let coverB = makeCover(at: shotsDir.appendingPathComponent("coverB.png"),
                               top: #colorLiteral(red: 0.37, green: 0.82, blue: 0.91, alpha: 1),
                               bottom: #colorLiteral(red: 0.05, green: 0.11, blue: 0.16, alpha: 1))

        let lines = (0..<20).map { i in
            "And the static hums \(i + 1) like a held breath in the dark"
        }
        let upcoming: [Prop] = [
            ("Coronal Rain", "Aurora Drift", 244), ("Tide Pool", "Kelp Liturgy", 198),
            ("Paper Lanterns", "Fen", 263), ("Low Orbit", "Aurora Drift", 221),
            ("Saltglass", "Kelp Liturgy", 187), ("Afterglow Band", "Fen", 305),
        ].enumerated().map { index, track in
            Prop.mapping([
                "title": .string(track.0),
                "artist": .string(track.1),
                "artworkURL": .string((index.isMultiple(of: 2) ? coverA : coverB).absoluteString),
                "duration": .number(track.2),
            ])
        }

        let resolver = PathBindingResolver([
            "player.title": { .string("Solar Flare") },
            "player.artist": { .string("Aurora Drift") },
            "player.album": { .string("Coronal Rain") },
            "player.artworkURL": { .string(coverA.absoluteString) },
            "player.isPlaying": { .flag(true) },
            "player.isPaused": { .flag(false) },
            "player.hasTrack": { .flag(true) },
            "player.progress": { .number(96) },
            "player.duration": { .number(247) },
            "player.progressClock": { .string("1:36") },
            "player.durationClock": { .string("4:07") },
            "player.volume": { .number(0.8) },
            "player.shuffleEnabled": { .flag(true) },
            "player.repeatMode": { .string("all") },
            "player.isBuffering": { .flag(false) },
            "player.upcomingTracks": { .list(upcoming) },
            "lyrics.currentLine": { .string(lines[7]) },
            "lyrics.lines": { .list(lines.map { Prop.string($0) }) },
            "lyrics.lineCount": { .number(Double(lines.count)) },
            "lyrics.currentIndex": { .number(7) },
            "app.nowPlayingOpen": { .flag(false) },
            "app.shaderName": { .string("bloom") },
            "app.themeName": { .string(store.currentTheme) },
            "app.themeNames": { .list(store.themes.keys.sorted().map { Prop.string($0) }) },
        ])

        let shots: [(String, String, CGFloat, CGFloat)] = [
            ("preview", "default", 400, 520),
            ("preview", "aurora", 400, 520),
            ("mini", "default", 400, 620),
            ("mini", "aurora", 400, 620),
            ("lyrics", "default", 400, 620),
            ("lyrics", "aurora", 400, 620),
        ]
        for (name, theme, width, height) in shots {
            store.setCurrentTheme(theme)
            guard let screen = store.screens[name] else {
                print("no screen: \(name)")
                continue
            }
            let view = ScreenView(root: screen.root, stylesheet: screen.stylesheet)
                .environment(\.bindingResolver, resolver)
                // Buttons disable themselves without a dispatcher (no
                // host); the shot injects a do-nothing registry so they
                // render lit.
                .environment(\.actionDispatcher, ActionRegistry())
            render(view, size: NSSize(width: width, height: height),
                   to: shotsDir.appendingPathComponent("\(name)-\(theme).png"))
        }
        print("shots in \(shotsDir.path)")
        app.terminate(nil)
    }

    /// Renders a view into a PNG. SwiftUI's ImageRenderer cannot capture
    /// the native controls these trees use (Slider, Button), so this goes
    /// the AppKit route: an offscreen window so the view gets a real
    /// appearance pass (AsyncImage starts loading, controls draw), a beat
    /// of run loop, then a bitmap cache of the view itself. The window sits
    /// far off-screen and never enters sight.
    private static func render<V: View>(_ view: V, size: NSSize, to url: URL) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        // AsyncImage loads on appearance; give it beats to land.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("no bitmap for \(url.lastPathComponent)")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        window.orderOut(nil)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            print("no png for \(url.lastPathComponent)")
            return
        }
        do {
            try png.write(to: url)
            print("wrote \(url.lastPathComponent)")
        } catch {
            print("write failed: \(error)")
        }
    }

    /// A simple two-stop gradient cover, so the Artwork component has a
    /// real image to load rather than a placeholder in every shot.
    private static func makeCover(at url: URL, top: NSColor, bottom: NSColor) -> URL {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()
        let gradient = NSGradient(starting: top, ending: bottom)
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: -90)
        let dot = NSBezierPath(ovalIn: NSRect(x: 176, y: 176, width: 160, height: 160))
        NSColor.white.withAlphaComponent(0.18).setFill()
        dot.fill()
        image.unlockFocus()
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        return url
    }
}
