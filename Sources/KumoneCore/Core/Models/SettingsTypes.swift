import Foundation

public enum AudioQuality: String, CaseIterable, Identifiable {
    case standard
    case higher
    case exhigh
    case lossless
    case hires

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: return String(localized: "标准")
        case .higher: return String(localized: "较高")
        case .exhigh: return String(localized: "极高")
        case .lossless: return String(localized: "无损")
        case .hires: return "Hi-Res"
        }
    }

    public var badge: String {
        switch self {
        case .standard: return String(localized: "标准")
        case .higher: return String(localized: "较高")
        case .exhigh: return String(localized: "极高")
        case .lossless: return String(localized: "无损")
        case .hires: return String(localized: "高解析")
        }
    }
}

public enum BrightnessIntent: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

public enum AppAppearance: String, CaseIterable, Identifiable {
    case auto, light, dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return String(localized: "跟随系统")
        case .light: return String(localized: "浅色")
        case .dark: return String(localized: "深色")
        }
    }

    public var brightnessIntent: BrightnessIntent {
        switch self {
        case .auto: return .system
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// What to show above Japanese lyrics.
public enum LyricsAnnotation: String, CaseIterable, Identifiable {
    case off
    case romaji
    case furigana

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return String(localized: "关闭")
        case .romaji: return String(localized: "罗马音")
        case .furigana: return String(localized: "汉字读音")
        }
    }
}

public enum NowPlayingMode: String, CaseIterable, Identifiable {
    case vinyl
    case classic
    case immersive
    case minimal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vinyl: return String(localized: "黑胶模式")
        case .classic: return String(localized: "经典模式")
        case .immersive: return String(localized: "沉浸模式")
        case .minimal: return String(localized: "简洁模式")
        }
    }
}

/// Configuration for a user-operated LX-Source service.
public struct LXSourceSettings: Equatable, Sendable {
    public var baseURL: String
    public var apiKey: String
    public var platform: String

    public init(baseURL: String = "", apiKey: String = "", platform: String = "wy") {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.platform = platform
    }

    public static var current: Self {
        Self(baseURL: UserDefaults.standard.string(forKey: "lx.baseURL") ?? "",
             apiKey: UserDefaults.standard.string(forKey: "lx.apiKey") ?? "",
             platform: UserDefaults.standard.string(forKey: "lx.platform") ?? "wy")
    }
}
