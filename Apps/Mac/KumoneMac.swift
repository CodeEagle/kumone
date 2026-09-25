import AppKit
import KumoneCore
import KumoneTCA

@main
@MainActor
enum KumoneMain {
    static func main() {
        // The music provider registry is process-global and read lazily when a
        // reducer first touches `@Dependency(\.musicProvider)`, which happens
        // while `AppDelegate` builds its store below — so registration must
        // precede it.
        MusicProviderKey.register(NetEaseMusicProvider(), for: .netease)
        MusicProviderKey.register(QQMusicProvider(), for: .qq)
        MusicProviderKey.register(KuwoMusicProvider(), for: .kuwo)

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
