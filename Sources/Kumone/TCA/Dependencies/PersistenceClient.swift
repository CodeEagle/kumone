import ComposableArchitecture
import Foundation

/// Keyed user defaults + ad-hoc file storage, behind a dependency so reducers
/// can read and persist settings / playback state without touching `UserDefaults`
/// or the disk directly (and tests can swap in an in-memory implementation).
@DependencyClient
struct PersistenceClient {
    /// Returns `false` for missing keys (matching `UserDefaults.bool`).
    var boolForKey: @Sendable (_ key: String) -> Bool = { _ in false }
    var setBool: @Sendable (_ value: Bool, _ key: String) -> Void = { _, _ in }

    var stringForKey: @Sendable (_ key: String) -> String? = { _ in nil }
    var setString: @Sendable (_ value: String?, _ key: String) -> Void = { _, _ in }

    var doubleForKey: @Sendable (_ key: String) -> Double = { _ in 0 }
    var setDouble: @Sendable (_ value: Double, _ key: String) -> Void = { _, _ in }

    var dataForKey: @Sendable (_ key: String) -> Data? = { _ in nil }
    var setData: @Sendable (_ value: Data?, _ key: String) -> Void = { _, _ in }
}

extension PersistenceClient: TestDependencyKey {
    public static let testValue = PersistenceClient()
}

extension PersistenceClient: DependencyKey {
    static let liveValue = PersistenceClient(
        boolForKey: { UserDefaults.standard.bool(forKey: $0) },
        setBool: { UserDefaults.standard.set($0, forKey: $1) },
        stringForKey: { UserDefaults.standard.string(forKey: $0) },
        setString: { UserDefaults.standard.set($0, forKey: $1) },
        doubleForKey: { UserDefaults.standard.double(forKey: $0) },
        setDouble: { UserDefaults.standard.set($0, forKey: $1) },
        dataForKey: { UserDefaults.standard.data(forKey: $0) },
        setData: { UserDefaults.standard.set($0, forKey: $1) }
    )
}

extension DependencyValues {
    var persistence: PersistenceClient {
        get { self[PersistenceClient.self] }
        set { self[PersistenceClient.self] = newValue }
    }
}
