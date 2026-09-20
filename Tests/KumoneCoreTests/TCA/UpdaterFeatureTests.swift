import ComposableArchitecture
import Dependencies
@testable import KumoneCore
import XCTest

@MainActor
final class UpdaterFeatureTests: XCTestCase {
    func testOnAppearStartsTheUpdaterAndReportsAvailability() async {
        let store = TestStore(initialState: UpdaterFeature.State()) {
            UpdaterFeature()
        } withDependencies: {
            $0.updater.start = {
                AsyncStream { continuation in
                    continuation.yield(true)
                    continuation.finish()
                }
            }
        }
        await store.send(.onAppear) {
            $0.isStarted = true
        }
        await store.receive(.canCheckForUpdatesChanged(true)) {
            $0.canCheckForUpdates = true
        }
    }

    func testOnAppearSubscribesOnlyOnce() async {
        let store = TestStore(initialState: UpdaterFeature.State(isStarted: true)) {
            UpdaterFeature()
        } withDependencies: {
            // Would hang the test if a second subscription were opened.
            $0.updater.start = { .never }
        }
        await store.send(.onAppear)
    }

    func testAvailabilityChangesUpdateTheState() async {
        let store = TestStore(initialState: UpdaterFeature.State()) {
            UpdaterFeature()
        }
        await store.send(.canCheckForUpdatesChanged(true)) {
            $0.canCheckForUpdates = true
        }
    }

    func testSetAutomaticChecksForwardsToTheClient() async {
        let store = TestStore(initialState: UpdaterFeature.State()) {
            UpdaterFeature()
        } withDependencies: {
            $0.updater.setAutomaticChecks = { XCTAssertEqual($0, true) }
        }
        await store.send(.setAutomaticChecks(true))
    }

    func testCheckForUpdatesForwardsToTheClient() async {
        let store = TestStore(initialState: UpdaterFeature.State()) {
            UpdaterFeature()
        } withDependencies: {
            $0.updater.checkForUpdates = {}
        }
        await store.send(.checkForUpdates)
    }
}
