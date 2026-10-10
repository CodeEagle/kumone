import XCTest
@testable import KumoneCore

final class BoundedLogFileTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kumone-bounded-log-\(UUID().uuidString).log")
    }

    /// Rollover is checked before a write, so the real bound is the cap plus
    /// one pending line — a probe that runs forever still stays bounded.
    private let line = String(repeating: "x", count: 256)

    func testRolloverCapsTheFile() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // 32 lines x 257 bytes far exceed the 1 KiB cap: the file must roll over.
        for _ in 0..<32 {
            BoundedLogFile.append(line, to: url, maxBytes: 1024)
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertLessThanOrEqual(size, 1024 + 257)
    }

    func testRolloverKeepsWholeLines() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        for index in 0..<16 {
            BoundedLogFile.append("line-\(index)", to: url, maxBytes: 64)
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        // A truncate-then-write must never leave a partial tail line behind:
        // every line in the file is a whole one.
        let prefix = "line-"
        for survivor in content.split(separator: "\n") {
            XCTAssertTrue(survivor.hasPrefix(prefix), "fragmented line: \(survivor)")
            let digits = survivor.dropFirst(prefix.count)
            XCTAssertFalse(digits.isEmpty, "fragmented line: \(survivor)")
            XCTAssertTrue(digits.allSatisfy(\.isNumber), "fragmented line: \(survivor)")
        }
        XCTAssertLessThanOrEqual(content.utf8.count, 64 + "line-15".count)
    }

    func testSmallFileDoesNotRollOver() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        for index in 0..<4 {
            BoundedLogFile.append("line-\(index)", to: url, maxBytes: 4096)
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(content.split(separator: "\n").count, 4)
    }
}
