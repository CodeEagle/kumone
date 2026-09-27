import Foundation
import Testing
@testable import KumoneCore

@Suite("GitHub release lookup")
struct ReleaseCheckerTests {
    // MARK: - Version comparison

    @Test func isNewerComparesNumericSegments() {
        #expect(ReleaseChecker.isNewer("1.2.3", than: "1.2.3") == false)
        #expect(ReleaseChecker.isNewer("1.2.4", than: "1.2.3") == true)
        #expect(ReleaseChecker.isNewer("1.2.2", than: "1.2.3") == false)
        #expect(ReleaseChecker.isNewer("1.3", than: "1.2.9") == true)
        #expect(ReleaseChecker.isNewer("2.0", than: "1.9.9") == true)
        #expect(ReleaseChecker.isNewer("1.10", than: "1.9") == true)
        #expect(ReleaseChecker.isNewer("10", than: "9") == true)
        #expect(ReleaseChecker.isNewer("0.9", than: "1") == false)
    }

    /// Missing segments compare as zero, so 1.0 and 1.0.0 are the same version.
    @Test func isNewerTreatsMissingSegmentsAsZero() {
        #expect(ReleaseChecker.isNewer("1.0", than: "1.0.0") == false)
        #expect(ReleaseChecker.isNewer("1.0.0", than: "1.0") == false)
        #expect(ReleaseChecker.isNewer("1.0.0.1", than: "1.0") == true)
        #expect(ReleaseChecker.isNewer("1", than: "1.0.0") == false)
    }

    /// Non-numeric segments fall back to zero rather than crashing or matching.
    @Test func isNewerFallsBackForNonNumericSegments() {
        #expect(ReleaseChecker.isNewer("2.x", than: "1") == true)
        #expect(ReleaseChecker.isNewer("1.x", than: "1") == false)
        #expect(ReleaseChecker.isNewer("1.0", than: "1.x") == false)
    }

    // MARK: - Payload decoding

    private static func payload(tag: String? = "v2.3.1", html: String? = "https://github.com/missuo/kumone/releases/tag/v2.3.1", assets: [[String: Any]]? = nil) -> Data {
        var object: [String: Any] = [:]
        if let tag { object["tag_name"] = tag }
        if let html { object["html_url"] = html }
        if let assets { object["assets"] = assets }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func decodesVersionPageAndIPA() throws {
        let data = Self.payload(assets: [
            ["name": "Kumone.ipa", "browser_download_url": "https://github.com/missuo/kumone/releases/download/v2.3.1/Kumone.ipa"],
            ["name": "Kumone.dmg", "browser_download_url": "https://github.com/missuo/kumone/releases/download/v2.3.1/Kumone.dmg"],
        ])
        let release = try ReleaseChecker.decodeRelease(from: data)
        #expect(release.version == "2.3.1")
        #expect(release.url.absoluteString == "https://github.com/missuo/kumone/releases/tag/v2.3.1")
        #expect(release.ipaURL?.absoluteString == "https://github.com/missuo/kumone/releases/download/v2.3.1/Kumone.ipa")
    }

    @Test func decodesVersionWithoutVPrefix() throws {
        let release = try ReleaseChecker.decodeRelease(from: Self.payload(tag: "2.3.1"))
        #expect(release.version == "2.3.1")
    }

    @Test func ipaURLIsNilWithoutAnIPAAsset() throws {
        let release = try ReleaseChecker.decodeRelease(from: Self.payload(assets: [
            ["name": "Kumone.dmg", "browser_download_url": "https://example.com/Kumone.dmg"],
        ]))
        #expect(release.ipaURL == nil)
    }

    @Test func matchesIPAAssetRegardlessOfCase() throws {
        let release = try ReleaseChecker.decodeRelease(from: Self.payload(assets: [
            ["name": "Kumone.IPA", "browser_download_url": "https://example.com/Kumone.IPA"],
        ]))
        #expect(release.ipaURL?.absoluteString == "https://example.com/Kumone.IPA")
    }

    @Test func rejectsPayloadWithoutATag() {
        #expect(throws: ReleaseChecker.Failure.decoding) {
            _ = try ReleaseChecker.decodeRelease(from: Self.payload(tag: nil))
        }
    }

    @Test func rejectsPayloadWithoutAPage() {
        #expect(throws: ReleaseChecker.Failure.decoding) {
            _ = try ReleaseChecker.decodeRelease(from: Self.payload(html: nil))
        }
    }

    @Test func rejectsNonObjectPayload() {
        let data = Data("[1, 2, 3]".utf8)
        #expect(throws: ReleaseChecker.Failure.self) {
            _ = try ReleaseChecker.decodeRelease(from: data)
        }
    }
}
