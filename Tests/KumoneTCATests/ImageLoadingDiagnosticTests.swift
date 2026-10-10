import ComposableArchitecture
import KumoneCore
import XCTest
#if os(macOS)
import APlay
import AppKit
import MediaPlayer
#endif
@testable import KumoneTCA

final class ImageLoadingDiagnosticTests: XCTestCase {
    #if os(macOS)
    @MainActor
    func testExplicitArtworkClearPreservesTextMetadata() async {
        let player = APlay(configuration: APlay.Configuration(enableRemoteCommandHandling: false))
        let image = NSImage(size: CGSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        player.metadataUpdate(title: "Diagnostic", artist: "Artist", cover: image)
        let populated = expectation(description: "artwork populated")
        DispatchQueue.main.async {
            XCTAssertNotNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork])
            populated.fulfill()
        }
        await fulfillment(of: [populated], timeout: 2)
        player.metadataUpdate(clearArtwork: true)
        let cleared = expectation(description: "artwork cleared")
        DispatchQueue.main.async {
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
            XCTAssertNil(info?[MPMediaItemPropertyArtwork])
            XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, "Diagnostic")
            XCTAssertEqual(info?[MPMediaItemPropertyArtist] as? String, "Artist")
            cleared.fulfill()
        }
        await fulfillment(of: [cleared], timeout: 2)
        withExtendedLifetime(player) {}
    }
    #endif
    @MainActor
    func testSettingsRoutesDiagnosticToGlobalImageGateAndRestoresIt() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        store.exhaustivity = .off
        await store.send(.settings(.setDisableImageLoading(true)))
        await store.receive(.imageLoadingDiagnosticApplied(true))
        XCTAssertTrue(store.state.settings.disableImageLoading)
        XCTAssertTrue(ImageLoadingControl.shared.isDisabled)
        await store.send(.settings(.setDisableImageLoading(false)))
        await store.receive(.imageLoadingDiagnosticApplied(false))
        XCTAssertFalse(store.state.settings.disableImageLoading)
        XCTAssertFalse(ImageLoadingControl.shared.isDisabled)
        await store.finish()
    }
}
