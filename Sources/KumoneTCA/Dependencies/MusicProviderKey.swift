// Sources/Kumone/TCA/Dependencies/MusicProviderKey.swift
//
// TCA `@Dependency` integration for the abstracted music provider (Phase 1).
// Per music-provider.md §3.3: no generics — the key erases to `any MusicProvider`.
// Access level is internal on purpose: `MusicProvider` and the models it references
// are internal (same target), and a `public` declaration referencing an internal
// type is a hard error in Swift. The raise happens with the multi-target split.

import ComposableArchitecture
import KumoneCore

/// Main provider key: resolves the live provider for the active `MusicProviderID`.
public struct MusicProviderKey: DependencyKey {
    /// 当前激活的 provider 标识。读写委托 Core 层单一源（`MusicProviderStorage`），
    /// 本 key 不另存 static，避免出现两份 activeProviderID。
    public static var activeProviderID: MusicProviderID {
        get { MusicProviderStorage.activeProviderID }
        set { MusicProviderStorage.activeProviderID = newValue }
    }

    /// 通过 providerID 查找 live 实现（进程级全局）。
    /// ⚠️ 测试隔离：static var 是进程级全局，并行测试会串扰。**单元测试不要依赖 registry**，
    /// 一律用 `withDependencies { $0.musicProvider = mock }` 直接覆盖整个 key，
    /// registry 仅用于 app 启动时选定生产 provider。
    static var registry: [MusicProviderID: any MusicProvider] = [:]

    public static var liveValue: any MusicProvider {
        guard let provider = registry[activeProviderID] else {
            fatalError("No MusicProvider registered for \(activeProviderID)")
        }
        return provider
    }
}

extension DependencyValues {
    public var musicProvider: any MusicProvider {
        get { self[MusicProviderKey.self] }
        set { self[MusicProviderKey.self] = newValue }
    }
}

/// 子能力 key（可选注入用）—— 与主 key 共享 registry：只有实现了 `MusicPersonalFM`
/// 的 provider（如 NetEase）才会被解析为非 nil，未实现的源返回 nil，UI 据此隐藏入口。
public struct MusicPersonalFMKey: DependencyKey {
    public static var liveValue: any MusicPersonalFM? {
        MusicProviderKey.registry[MusicProviderKey.activeProviderID] as? any MusicPersonalFM
    }
}

extension DependencyValues {
    public var personalFM: any MusicPersonalFM? {
        get { self[MusicPersonalFMKey.self] }
        set { self[MusicPersonalFMKey.self] = newValue }
    }
}

/// Optional capability resolved from the active provider; unsupported providers return nil.
public struct MusicPlayHistoryKey: DependencyKey {
    public static var liveValue: any MusicPlayHistory? {
        MusicProviderKey.registry[MusicProviderKey.activeProviderID] as? any MusicPlayHistory
    }
}

extension DependencyValues {
    public var playHistory: any MusicPlayHistory? {
        get { self[MusicPlayHistoryKey.self] }
        set { self[MusicPlayHistoryKey.self] = newValue }
    }
}

/// Optional capability resolved from the active provider; unsupported providers return nil.
public struct MusicCloudStorageKey: DependencyKey {
    public static var liveValue: any MusicCloudStorage? {
        MusicProviderKey.registry[MusicProviderKey.activeProviderID] as? any MusicCloudStorage
    }
}

extension DependencyValues {
    public var cloudStorage: any MusicCloudStorage? {
        get { self[MusicCloudStorageKey.self] }
        set { self[MusicCloudStorageKey.self] = newValue }
    }
}

/// Optional capability resolved from the active provider; unsupported providers return nil.
public struct MusicIntelligenceKey: DependencyKey {
    public static var liveValue: any MusicIntelligence? {
        MusicProviderKey.registry[MusicProviderKey.activeProviderID] as? any MusicIntelligence
    }
}

extension DependencyValues {
    public var intelligence: any MusicIntelligence? {
        get { self[MusicIntelligenceKey.self] }
        set { self[MusicIntelligenceKey.self] = newValue }
    }
}

extension MusicProviderKey {
    /// executable 层在启动最早期注册各 provider 的 live 实现。
    ///
    /// registry 保持 internal：注册入口只接已构造好的 `any MusicProvider`
    /// （public 协议），由各 executable 决定注册哪些源——不同平台/target
    /// 可注册不同集合（SF-0014 决策 8）。
    public static func register(_ provider: any MusicProvider, for id: MusicProviderID) {
        registry[id] = provider
    }
}
