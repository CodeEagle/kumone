import ComposableArchitecture
import KumoneCore
import KumoneTCA
import UIKit

@MainActor
final class TVRootViewController: UIViewController {
    private let store = StoreOf<AppFeature>(initialState: AppFeature.State()) { AppFeature() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let label = UILabel()
        label.text = "Kumone (tvOS)"
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
}
