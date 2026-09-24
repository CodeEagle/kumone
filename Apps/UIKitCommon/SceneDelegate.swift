import UIKit

@MainActor
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        #if os(visionOS)
        window.rootViewController = VisionRootViewController()
        #elseif os(tvOS)
        window.rootViewController = TVRootViewController()
        #else
        let root = UIViewController()
        #if os(tvOS)
        root.view.backgroundColor = .black
        #else
        root.view.backgroundColor = .systemBackground
        #endif
        let label = UILabel()
        label.text = "Kumone (UIKit placeholder)"
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: root.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: root.view.centerYAnchor)
        ])
        window.rootViewController = root
        #endif
        self.window = window
        window.makeKeyAndVisible()
    }
}
