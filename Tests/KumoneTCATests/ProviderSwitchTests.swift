import KumoneCore
@testable import KumoneTCA
import XCTest

@MainActor
final class ProviderSwitchTests: XCTestCase {
    /// 本测试专门验证 registry 解析，故不使用 withDependencies 覆盖结果。
    /// 修改全局状态的窗口不跨 await，并恢复完整快照（通常为 .netease）。
    private func resolveProviders() -> (qq: any MusicProvider, unregistered: any MusicProvider) {
        let originalRegistry = MusicProviderKey.registry
        let originalID = MusicProviderKey.activeProviderID
        defer {
            MusicProviderKey.registry = originalRegistry
            MusicProviderKey.activeProviderID = originalID
        }

        MusicProviderKey.register(NetEaseMusicProvider(), for: .netease)
        MusicProviderKey.register(QQMusicProvider(), for: .qq)
        MusicProviderKey.activeProviderID = .netease
        XCTAssertTrue(MusicProviderKey.liveValue is NetEaseMusicProvider)
        assertOptionalCapabilities(available: true)

        MusicProviderKey.activeProviderID = .qq
        let qq = MusicProviderKey.liveValue
        XCTAssertTrue(qq is QQMusicProvider)
        XCTAssertFalse(qq.isLoggedIn)
        XCTAssertTrue(qq.supportedMethods.isEmpty)
        XCTAssertEqual(qq.qrLoginURL("unused").absoluteString, "about:blank")
        assertOptionalCapabilities(available: false)

        MusicProviderKey.registry.removeValue(forKey: .kuwo)
        MusicProviderKey.activeProviderID = .kuwo
        let unregistered = MusicProviderKey.liveValue
        XCTAssertTrue(unregistered is UnimplementedProvider)
        XCTAssertFalse(unregistered.isLoggedIn)
        XCTAssertTrue(unregistered.supportedMethods.isEmpty)
        assertOptionalCapabilities(available: false)

        MusicProviderKey.activeProviderID = .netease
        XCTAssertTrue(MusicProviderKey.liveValue is NetEaseMusicProvider)
        assertOptionalCapabilities(available: true)
        return (qq, unregistered)
    }

    private func assertOptionalCapabilities(available: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(MusicPersonalFMKey.liveValue != nil, available, file: file, line: line)
        XCTAssertEqual(MusicCloudStorageKey.liveValue != nil, available, file: file, line: line)
        XCTAssertEqual(MusicIntelligenceKey.liveValue != nil, available, file: file, line: line)
        XCTAssertEqual(MusicPlayHistoryKey.liveValue != nil, available, file: file, line: line)
    }

    func testSwitchingResolvesPartialProviderAndUnregisteredFallback() async {
        // 先同步解析并恢复全局状态，再调用无状态 provider，避免 await 期间污染其它测试。
        let providers = resolveProviders()
        for provider in [providers.qq, providers.unregistered] {
            do {
                _ = try await provider.search("测试", category: .songs, limit: 10, offset: 0)
                XCTFail("未接入的搜索能力应抛错")
            } catch UnimplementedProviderError.search {
                XCTAssertEqual(UnimplementedProviderError.search.errorDescription, "该源未实现搜索能力域")
            } catch {
                XCTFail("搜索返回了非预期错误：\(error)")
            }

            do {
                _ = try await provider.playlistDetail(id: .source(id: "test", provider: .qq))
                XCTFail("未接入的歌单能力应抛错")
            } catch UnimplementedProviderError.playlist {
                // 精确匹配能力域，而非接受任意错误。
            } catch {
                XCTFail("歌单返回了非预期错误：\(error)")
            }
        }
    }
}
