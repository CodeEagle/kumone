import KumoneCore
import Foundation
import ComposableArchitecture
import Dependencies
@testable import KumoneTCA
import XCTest

@MainActor
final class ToastsFeatureTests: XCTestCase {
    func testPresentShowsToastThenAutoDismisses() async {
        let id = UUID()
        let store = TestStore(initialState: ToastsFeature.State()) {
            ToastsFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.uuid = .init { id }
        }
        await store.send(.presented("hello")) {
            $0.current = Toast(id: id, message: "hello")
        }
        // ImmediateClock fires the 3s timer immediately: the toast clears.
        await store.receive(\.autoDismissTimerCompleted) {
            $0.current = nil
        }
    }

    func testStaleTimerDoesNotClearNewerToast() async {
        let firstID = UUID()
        let secondID = UUID()
        nonisolated(unsafe) var uuids = [firstID, secondID].makeIterator()
        let store = TestStore(initialState: ToastsFeature.State()) {
            ToastsFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.uuid = .init { uuids.next()! }
        }
        await store.send(.presented("first")) {
            $0.current = Toast(id: firstID, message: "first")
        }
        // Replaces the first toast. Its own timer is now the live one.
        await store.send(.presented("second")) {
            $0.current = Toast(id: secondID, message: "second")
        }
        // The FIRST toast's stale timer fires — it must not clear the second
        // toast, so state is unchanged.
        await store.receive(\.autoDismissTimerCompleted)
        // The second toast's own timer then clears it.
        await store.receive(\.autoDismissTimerCompleted) {
            $0.current = nil
        }
    }

    func testDismissClearsImmediately() async {
        let id = UUID()
        let store = TestStore(initialState: ToastsFeature.State()) {
            ToastsFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.uuid = .init { id }
        }
        await store.send(.presented("hi")) {
            $0.current = Toast(id: id, message: "hi")
        }
        await store.send(.dismiss) {
            $0.current = nil
        }
        // The pending auto-dismiss timer is now moot, but must still complete.
        await store.receive(\.autoDismissTimerCompleted)
    }
    func testDismissAndStaleTimerWithoutToastDoNothing() async {
        let store = TestStore(initialState: ToastsFeature.State()) { ToastsFeature() }
        await store.send(.dismiss)
        await store.send(.autoDismissTimerCompleted(UUID()))
    }

}
