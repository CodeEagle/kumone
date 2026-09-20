import ComposableArchitecture
import Dependencies
import Foundation

/// The composition root. Child features own their state and logic; this reducer
/// only wires cross-feature effects: the sidebar selection, the detail stack,
/// login → bootstrap, content delegates → player/toasts/library, and the
/// settings/account values the player mirrors at resolve time.
@Reducer
struct AppFeature {
    @ObservableState
    struct State: Equatable {
        var toasts = ToastsFeature.State()
        var settings = SettingsFeature.State()
        var account = AccountFeature.State()
        var login = LoginFeature.State()
        var player = PlayerFeature.State()
        var updater = UpdaterFeature.State()

        // Sidebar pages that stay alive across switches.
        var home = HomeFeature.State()
        var explore = ExploreFeature.State()
        var search = SearchFeature.State()
        var daily = DailySongsFeature.State()
        var recents = RecentsFeature.State()
        var cloud = CloudFeature.State()
        var collections = CollectionsFeature.State()
        /// The playlist the sidebar points at directly (我喜欢的音乐 and
        /// pinned playlists), rendered as the detail column's root.
        var playlistRoot = PlaylistDetailFeature.State(playlistID: 0)

        var selection: SidebarItem = .home
        var path = StackState<Path.State>()
        var isLoginPresented = false
    }

    enum Action: Equatable {
        case toasts(ToastsFeature.Action)
        case settings(SettingsFeature.Action)
        case account(AccountFeature.Action)
        case login(LoginFeature.Action)
        case player(PlayerFeature.Action)
        case updater(UpdaterFeature.Action)
        case home(HomeFeature.Action)
        case explore(ExploreFeature.Action)
        case search(SearchFeature.Action)
        case daily(DailySongsFeature.Action)
        case recents(RecentsFeature.Action)
        case cloud(CloudFeature.Action)
        case collections(CollectionsFeature.Action)
        case playlistRoot(PlaylistDetailFeature.Action)
        case path(StackActionOf<Path>)

        case selectionChanged(SidebarItem)
        /// A destination asked for from outside the sidebar (the toolbar search
        /// field, now-playing links, the Dock menu).
        case openDestination(Destination)

        case presentLogin
        case dismissLogin

        /// App launch: rehydrate settings, load the account, start the updater,
        /// and listen for system media commands.
        case onAppear

        /// A system Now Playing event (media keys, Control Center, lock screen,
        /// CarPlay) turned into an action the store can route.
        case nowPlaying(NowPlayingCommand)
    }

    /// Pages pushed onto the detail stack.
    @Reducer(state: .equatable, action: .equatable)
    enum Path {
        case playlist(PlaylistDetailFeature)
        /// The radar family, whose recommendations come from a different pool.
        case radarPlaylist(PlaylistDetailFeature)
        case album(AlbumDetailFeature)
        case artist(ArtistDetailFeature)
        case search(SearchFeature)
        case daily(DailySongsFeature)
        case recents(RecentsFeature)
        case collections(CollectionsFeature)
        case cloud(CloudFeature)
        case toplists(ToplistsFeature)
    }

    @Dependency(\.nowPlaying) var nowPlaying

    var body: some ReducerOf<Self> {
        Scope(state: \.toasts, action: \.toasts) { ToastsFeature() }
        Scope(state: \.settings, action: \.settings) { SettingsFeature() }
        Scope(state: \.account, action: \.account) { AccountFeature() }
        Scope(state: \.login, action: \.login) { LoginFeature() }
        Scope(state: \.player, action: \.player) { PlayerFeature() }
        Scope(state: \.updater, action: \.updater) { UpdaterFeature() }
        Scope(state: \.home, action: \.home) { HomeFeature() }
        Scope(state: \.explore, action: \.explore) { ExploreFeature() }
        Scope(state: \.search, action: \.search) { SearchFeature() }
        Scope(state: \.daily, action: \.daily) { DailySongsFeature() }
        Scope(state: \.recents, action: \.recents) { RecentsFeature() }
        Scope(state: \.cloud, action: \.cloud) { CloudFeature() }
        Scope(state: \.collections, action: \.collections) { CollectionsFeature() }
        Scope(state: \.playlistRoot, action: \.playlistRoot) { PlaylistDetailFeature() }

        Reduce { state, action in
            switch action {
            case .selectionChanged(let selection):
                state.selection = selection
                // Switching the sidebar page pops everything pushed above it.
                state.path.removeAll()
                switch selection {
                case .likedSongs:
                    if let playlist = state.account.likedSongsPlaylist {
                        state.playlistRoot = PlaylistDetailFeature.State(playlistID: playlist.id)
                    }
                case .playlist(let id):
                    state.playlistRoot = PlaylistDetailFeature.State(playlistID: id)
                default:
                    break
                }
                return .none

            case .openDestination(let destination):
                guard var element = Self.pathElement(for: destination) else { return .none }
                applyAccountContext(to: &element, state: state)
                // The same page twice in a row is a no-op.
                if state.path.last == element { return .none }
                state.path.append(element)
                return .none

            case .onAppear:
                return .merge(
                    .send(.settings(.onAppear)),
                    .send(.account(.bootstrap)),
                    .send(.updater(.onAppear)),
                    .run { send in
                        for await command in nowPlaying.attach() {
                            await send(.nowPlaying(command))
                        }
                    }
                )

            // A system media event: routed with store state in hand so the
            // transport and like decisions see the current track.
            case .nowPlaying(let command):
                switch command {
                case .play where !state.player.isPlaying,
                     .pause where state.player.isPlaying:
                    return .send(.player(.togglePlayPause))
                case .togglePlayPause:
                    return .send(.player(.togglePlayPause))
                case .next:
                    return .send(.player(.next))
                case .previous:
                    return .send(.player(.previous))
                case let .seek(position):
                    return .send(.player(.seek(position)))
                case .like:
                    guard let trackID = state.player.currentTrack?.id else { return .none }
                    return .send(.account(.toggleLike(trackID)))
                case let .shuffle(on) where state.player.shuffleEnabled != on:
                    return .send(.player(.toggleShuffle))
                case let .repeatMode(mode) where state.player.repeatMode != mode:
                    return .send(.player(.setRepeatMode(mode)))
                default:
                    return .none
                }

            case .presentLogin:
                state.isLoginPresented = true
                return .send(.login(.onAppear))

            case .dismissLogin:
                state.isLoginPresented = false
                return .send(.login(.dismiss))

            // A login (QR or SMS) landed its cookies: load the account.
            case .login(.loginSucceeded):
                state.isLoginPresented = false
                return .send(.account(.bootstrap))

            // Settings finished rehydrating from disk: hand the persisted
            // auto-check preference to Sparkle.
            case .settings(.onAppear):
                return .send(.updater(.setAutomaticChecks(state.settings.autoCheckUpdates)))

            case .settings(.setAutoCheckUpdates(let enabled)):
                return .send(.updater(.setAutomaticChecks(enabled)))

            // "检查更新…" from the app menu or the Settings view.
            case .settings(.checkForUpdates):
                return .send(.updater(.checkForUpdates))

            // "欢迎回来" needs the profile, so it fires after bootstrap rather
            // than at login time.
            case let .account(.bootstrapResponse(.success(profile?))):
                let nickname = profile.nickname
                return .send(.toasts(.presented(String(localized: "欢迎回来，\(nickname)"))))

            case let .account(.toggleLikeFailed(error)):
                return .send(.toasts(.presented(error.message)))

            // The player surfaces this for the toast overlay; it carries no
            // state of its own.
            case let .player(.toast(message)):
                return .send(.toasts(.presented(message)))

            // Content pages handing the queue to the player.
            case let .playlistRoot(.delegate(.play(tracks, source, context))),
                 let .path(.element(_, .playlist(.delegate(.play(tracks, source, context))))),
                 let .path(.element(_, .radarPlaylist(.delegate(.play(tracks, source, context))))),
                 let .path(.element(_, .album(.delegate(.play(tracks, source, context))))),
                 let .path(.element(_, .artist(.delegate(.play(tracks, source, context))))),
                 let .path(.element(_, .daily(.delegate(.play(tracks, source, context))))),
                 let .path(.element(_, .cloud(.delegate(.play(tracks, source, context))))):
                return .send(.player(.play(tracks: tracks, source: source, startAt: nil, context: context)))

            case let .path(.element(_, .recents(.delegate(.play(tracks, startAt, context))))):
                return .send(.player(.play(tracks: tracks, source: .none, startAt: startAt, context: context)))

            // Failures and confirmations surface as toasts.
            case let .playlistRoot(.delegate(.toast(message))),
                 let .path(.element(_, .playlist(.delegate(.toast(message))))),
                 let .path(.element(_, .radarPlaylist(.delegate(.toast(message))))),
                 let .path(.element(_, .album(.delegate(.toast(message))))),
                 let .path(.element(_, .artist(.delegate(.toast(message))))):
                return .send(.toasts(.presented(message)))

            // A playlist subscription changed: the library lists move with it.
            case .playlistRoot(.delegate(.subscriptionChanged)),
                 .path(.element(_, .playlist(.delegate(.subscriptionChanged)))),
                 .path(.element(_, .radarPlaylist(.delegate(.subscriptionChanged)))):
                return .send(.account(.refreshLibrary))

            case .path(.element(_, .collections(.delegate(.refreshSublists)))):
                return .send(.account(.refreshSublists))

            default:
                return .none
            }
        }
        .forEach(\.path, action: \.path)

        // Mirrors the values the player reads at URL-resolve time. Runs after the
        // child scopes so it sees the updated sibling state, and handles every
        // child action — the specific cases above return effects and would
        // otherwise skip the sync.
        Reduce { state, action in
            switch action {
            case .settings:
                state.player.audioQuality = state.settings.audioQuality
                state.player.enableUnblock = state.settings.enableUnblock
                state.playlistRoot.enableUnblock = state.settings.enableUnblock
            case .account:
                state.player.isLoggedIn = state.account.isLoggedIn
                state.player.vipType = state.account.vipType
                state.home.isLoggedIn = state.account.isLoggedIn
                state.daily.isLoggedIn = state.account.isLoggedIn
                state.recents.userID = state.account.profile?.userId
                state.playlistRoot.isLoggedIn = state.account.isLoggedIn
                state.playlistRoot.vipType = state.account.vipType
                mirrorNowPlaying(to: &state)
            case .player:
                mirrorNowPlaying(to: &state)
            default:
                break
            }
            return .none
        }
    }

    /// Mirrors the values the system's Now Playing surfaces render: the like
    /// button's state (which needs both the current track and the account's
    /// liked IDs) plus shuffle and repeat. The client de-duplicates, so calling
    /// this on every player/account action is cheap.
    private func mirrorNowPlaying(to state: inout State) {
        let liked = state.player.currentTrack.map { state.account.isLiked($0.id) } ?? false
        nowPlaying.setLiked(liked)
        nowPlaying.setShuffle(state.player.shuffleEnabled)
        nowPlaying.setRepeat(state.player.repeatMode)
    }

    /// Copies the account/settings context a pushed page needs to decide what
    /// is playable, snapshot at push time (a pushed page does not follow later
    /// login or settings changes).
    private func applyAccountContext(
        to element: inout Path.State, state: State
    ) {
        switch element {
        case .playlist(var detail), .radarPlaylist(var detail):
            detail.isLoggedIn = state.account.isLoggedIn
            detail.vipType = state.account.vipType
            detail.enableUnblock = state.settings.enableUnblock
            if case .playlist = element { element = .playlist(detail) }
            else { element = .radarPlaylist(detail) }
        default:
            break
        }
    }

    /// Maps a view-level destination onto the state a pushed page needs.
    static func pathElement(for destination: Destination) -> Path.State? {
        switch destination {
        case .playlist(let id):
            return .playlist(PlaylistDetailFeature.State(playlistID: id))
        case .radarPlaylist(let id):
            return .radarPlaylist(PlaylistDetailFeature.State(playlistID: id))
        case .album(let id):
            return .album(AlbumDetailFeature.State(albumID: id))
        case .artist(let id):
            return .artist(ArtistDetailFeature.State(artistID: id))
        case .daily:
            return .daily(DailySongsFeature.State())
        case .toplists:
            return .toplists(ToplistsFeature.State())
        case .recents:
            return .recents(RecentsFeature.State())
        case .collections:
            return .collections(CollectionsFeature.State())
        case .cloud:
            return .cloud(CloudFeature.State())
        case .search(let query):
            return .search(SearchFeature.State(query: query))
        }
    }
}
