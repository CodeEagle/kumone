import Foundation
import XCTest
@testable import KumoneTCA

final class AudioCacheMaintenanceTests: XCTestCase {
    func testEvictsOldFilesButKeepsActiveContainerAndSidecar() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, name) in ["old", "new", "active.part", "active.part.meta"].enumerated() {
            let file = root.appendingPathComponent(name)
            try Data(repeating: 1, count: 100).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: file.path)
        }
        AudioCacheMaintenance.trimSynchronously(at: root, limit: 250, protecting: "active")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("old").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("active.part").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("active.part.meta").path))
    }
}
