import Foundation
import XCTest
@testable import KumoneCore

final class NeteaseMusicProviderTests: XCTestCase {
    func testSongURLRejectsInvalidIDsBeforeRequestingBatch() async {
        let invalidIDs: [MusicID] = [
            .source(id: "not-a-number", provider: .netease),
            .source(id: "", provider: .netease),
            .source(id: "0", provider: .netease),
            .source(id: "-1", provider: .netease),
            .source(id: "1.5", provider: .netease),
            .source(id: String(Int.max) + "0", provider: .netease),
            .source(id: "123", provider: .qq),
            .source(id: "123", provider: .kuwo),
            .source(id: "123", provider: .lx),
        ]
        for id in invalidIDs {
            for ids in [[id], [MusicID(123), id]] {
                do {
                    _ = try await NetEaseMusicProvider().songURL(ids: ids, quality: .standard)
                    XCTFail("Expected invalid ID rejection: \(id)")
                } catch NeteaseAPIError.business(let code, let message) {
                    XCTAssertEqual(code, -1)
                    XCTAssertEqual(message, "网易歌曲 ID 无效：必须是网易来源的正整数 ID")
                } catch {
                    XCTFail("Expected local business error, got \(error)")
                }
            }
        }
    }
}
