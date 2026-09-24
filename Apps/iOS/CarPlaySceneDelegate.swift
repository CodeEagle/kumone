import CarPlay
import KumoneTCA

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        IOSceneBootstrap.store
        // 后续转发到 KumoneTCA 的 CarPlayConnector.shared
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        // 后续转发到 KumoneTCA 的 CarPlayConnector.shared
    }
}
