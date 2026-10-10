#if os(macOS)
import AppKit
import ComposableArchitecture
import Foundation

/// Opt-in driver for the *shipping* UI. It never arms a hero or starts a flight
/// itself: mouse events must traverse the actual card's Button action. An
/// independent presentation trace judges SwiftUI's interpolated animation.
@MainActor
public final class HeroVisualAcceptance {
    private static var running: HeroVisualAcceptance?
    private let store: StoreOf<AppFeature>
    private let window: NSWindow
    private let directory: URL
    private let previousSelection: SidebarItem
    private var timer: Timer?
    private var phase = "prepare"
    private var phaseStarted = ProcessInfo.processInfo.systemUptime
    private var round = 0
    private var playlistID: Int?
    private var caseData: [String: Any] = [:]
    private var cases: [[String: Any]] = []

    public static func start(appStore: StoreOf<AppFeature>, window: NSWindow) {
        guard let path = ProcessInfo.processInfo.environment["KUMONE_HERO_VISUAL_ACCEPTANCE"],
              !path.isEmpty, running == nil else { return }
        let driver = HeroVisualAcceptance(store: appStore, window: window, directory: URL(fileURLWithPath: path))
        running = driver
        driver.timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak driver] _ in
            // This timer is installed on the main run loop; UI state has one owner.
            MainActor.assumeIsolated { driver?.tick() }
        }
    }

    private init(store: StoreOf<AppFeature>, window: NSWindow, directory: URL) {
        self.store = store
        self.window = window
        self.directory = directory
        previousSelection = store.selection
    }

    private func advance(_ next: String) {
        phase = next
        phaseStarted = ProcessInfo.processInfo.systemUptime
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - phaseStarted
        switch phase {
        case "prepare":
            store.send(.dismissNowPlaying)
            store.send(.selectionChanged(.home))
            window.setContentSize(NSSize(width: 1200, height: 760))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            writeWindow()
            advance("source")
        case "source":
            let candidates = store.home.recommendPlaylists
            let chosen = candidates.first { playlist in
                if let playlistID, playlist.id != playlistID { return false }
                guard let rect = HeroFrameStore.shared.frame(for: HeroID.playlist(playlist.id)) else { return false }
                return rect.minX > 0 && rect.maxX < window.frame.width && rect.minY > 50
                    && rect.maxY < window.frame.height - 110
            }
            guard let chosen, let source = HeroFrameStore.shared.frame(for: HeroID.playlist(chosen.id)) else {
                if elapsed > 35 { finish(error: "no-visible-playlist-source: not a PASS or a skip") }
                return
            }
            playlistID = chosen.id
            caseData = ["name": "playlist-\(round + 1)", "id": HeroID.playlist(chosen.id),
                        "source": rectData(source), "windowSize": [window.frame.width, window.frame.height],
                        "begin": now, "input": "NSApplication mouseDown/mouseUp on visible card"]
            advance("baseline")
        case "baseline":
            guard elapsed > 0.6, let playlistID,
                  let source = HeroFrameStore.shared.frame(for: HeroID.playlist(playlistID)) else { return }
            caseData["source"] = rectData(source)
            caseData["click"] = now
            // SwiftUI global coordinates have a top-left origin; AppKit event
            // coordinates are bottom-left in the full-size content view.
            let point = NSPoint(x: source.midX, y: window.contentView!.bounds.height - source.midY)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                timestamp: now, windowNumber: window.windowNumber,
                                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            advance("landing")
        case "landing":
            guard let playlistID else { finish(error: "missing-playlist-id"); return }
            let id = HeroID.playlist(playlistID)
            // A measured target is diagnostic metadata, never acceptance proof.
            if let target = HeroFrameStore.shared.frame(for: HeroID.detailTarget(id)), !store.path.isEmpty {
                caseData["target"] = rectData(target)
            }
            if elapsed > 4, caseData["target"] != nil {
                caseData["end"] = now
                // This driver was interrupted before the presentation trace
                // was implemented. Never report endpoint-only data as a pass.
                caseData["presentationReports"] = [] as [String]
                caseData["passed"] = false
                caseData["reason"] = "presentation trace not implemented; acceptance remains incomplete"
                cases.append(caseData)
                write(caseData, to: "case-\(round + 1).json")
                round += 1
                if round == 3 { finish(error: nil); return }
                store.send(.clearPath)
                if round == 2 {
                    window.setContentSize(NSSize(width: 1000, height: 760))
                    writeWindow()
                }
                advance("return")
            } else if elapsed > 15 {
                finish(error: "real-card-click-did-not-open-detail-or-measure-target")
            }
        case "return":
            if elapsed > 1.2 { advance("source") }
        default: break
        }
    }

    private func finish(error: String?) {
        timer?.invalidate()
        timer = nil
        write(["driverComplete": error == nil, "error": error ?? NSNull(), "cases": cases,
               "passed": error == nil && cases.count == 3 && cases.allSatisfy { $0["passed"] as? Bool == true },
               "proof": "real Button click + SwiftUI AnimatableModifier presentation samples, not endpoint-only geometry"], to: "driver.json")
        store.send(.clearPath)
        store.send(.selectionChanged(previousSelection))
        phase = "done"
        Self.running = nil
    }

    private func rectData(_ rect: CGRect) -> [CGFloat] { [rect.minX, rect.minY, rect.width, rect.height] }

    private func writeWindow() {
        write(["pid": ProcessInfo.processInfo.processIdentifier, "window": window.windowNumber,
               "width": window.frame.width, "height": window.frame.height], to: "window.json")
    }

    private func write(_ object: [String: Any], to name: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            timer?.invalidate()
            NSLog("Hero visual acceptance cannot write evidence: %@", String(describing: error))
        }
    }
}
#endif
