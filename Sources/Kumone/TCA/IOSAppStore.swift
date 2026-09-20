import ComposableArchitecture

#if os(iOS)
/// The one `AppFeature` store for the whole iOS process.
///
/// iOS runs two scenes — the main window and CarPlay — in one process, and
/// both must see (and mutate) the same source of truth. A store held in a
/// `@StateObject` on `IOSMainWindow` would be invisible to the CarPlay scene,
/// so the store lives here and both scenes read this constant. `AppFeature`
/// guards its own `onAppear`, so either scene may bootstrap it.
@MainActor
enum IOSAppStore {
    static let store = Store(initialState: AppFeature.State()) {
        AppFeature()
    }
}
#endif
