import Foundation
import Testing

@Suite("Fork feature localization resources")
struct LocalizationTests {
    private func languageBundle(_ language: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try #require(Bundle(path: root.appendingPathComponent(
            "Sources/Kumone/Resources/\(language).lproj").path))
    }

    @Test func addedFeaturesResolveInBothLanguages() throws {
        let english = try languageBundle("en")
        let chinese = try languageBundle("zh-Hans")
        let labels = [
            "快捷键": "Keyboard Shortcuts",
            "菜单栏播放控制": "Menu Bar Playback Controls",
            "主界面环境色": "Main Window Ambient Background",
            "歌曲缓存": "Audio Cache",
            "逐字歌词（卡拉OK）": "Word-by-Word Lyrics (Karaoke)",
            "导入 Shader…": "Import Shader…",
            "音频响应": "Audio Response",
            "开启 Zen 模式": "Turn On Zen Mode",
            "黑胶模式": "Vinyl",
            "沉浸模式": "Immersive"
        ]
        for (key, value) in labels {
            #expect(english.localizedString(forKey: key, value: nil, table: nil) == value)
            #expect(chinese.localizedString(forKey: key, value: nil, table: nil) == key)
        }
    }

    @Test func formattedMessagesPreserveValuesAndTranslateSurroundingText() throws {
        let english = try languageBundle("en")
        let chinese = try languageBundle("zh-Hans")
        let cases: [(String, [CVarArg], String, String)] = [
            ("已导入 %@", ["CustomShader"], "Imported CustomShader", "已导入 CustomShader"),
            ("打开歌手：%@", ["Artist Name"], "Open artist: Artist Name", "打开歌手：Artist Name"),
            ("无法安装全局快捷键：%d", [Int32(-1)], "Unable to install global shortcuts: -1", "无法安装全局快捷键：-1"),
            ("即将播放 · %lld 首", [Int64(42)], "Up Next · 42 songs", "即将播放 · 42 首")
        ]
        for (key, arguments, expectedEnglish, expectedChinese) in cases {
            #expect(String(format: english.localizedString(forKey: key, value: nil, table: nil),
                           arguments: arguments) == expectedEnglish)
            #expect(String(format: chinese.localizedString(forKey: key, value: nil, table: nil),
                           arguments: arguments) == expectedChinese)
        }
    }
}
