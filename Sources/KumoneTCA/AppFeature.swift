import ComposableArchitecture
import Dependencies
import Foundation
import KumoneCore

/// The composition root. Child features own their state and logic; this reducer
/// only wires cross-feature effects: the sidebar selection, the detail stack,
/// login → bootstrap, content delegates → player/toasts/library, and the
/// settings/account values the player mirrors at resolve time.
@Reducer
public struct AppFeature {
    /// Lets app targets (Mac/iOS/TV) construct the composition root.
    public init() {}

    @ObservableState
    public struct State: Equatable {
        public var toasts = ToastsFeature.State()
        public var settings = SettingsFeature.State()
        public var account = AccountFeature.State()
        public var login = LoginFeature.State()
        public var player = PlayerFeature.State()
        public var updater = UpdaterFeature.State()

        // Sidebar pages that stay alive across switches.
        public var home = HomeFeature.State()
        public var explore = ExploreFeature.State()
        public var search = SearchFeature.State()
        public var daily = DailySongsFeature.State()
        public var recents = RecentsFeature.State()
        public var cloud = CloudFeature.State()
        public var collections = CollectionsFeature.State()
        /// The playlist the sidebar points at directly (我喜欢的音乐 and
        /// pinned playlists), rendered as the detail column's root.
        public var playlistRoot = PlaylistDetailFeature.State(playlistID: 0)

        public var selection: SidebarItem = .home
        public var path = StackState<Path.State>()
        public var isLoginPresented = false
        /// The immersive Now Playing page (replaces `PlayerService.showNowPlaying`).
        public var isNowPlayingPresented = false
        public var shaderID: String? = nil
        /// Guards `onAppear` — iOS runs the main window and CarPlay in one
        /// process over one shared store, and either scene may bootstrap it.
        public var isAppeared = false

        /// Lets app targets (Mac/iOS/TV) construct the composition root's state.
        public init() {}
    }

    public enum Action: Equatable {
        case imageLoadingDiagnosticApplied(Bool)
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
        /// Drops the detail stack back to the root. The iPhone tab bar switches
        /// between five stacks that all share `path`; clearing on the switch
        /// keeps each tab rooted.
        case clearPath

        case presentLogin
        case dismissLogin

        /// Opens / closes the immersive Now Playing page.
        case presentNowPlaying
        case dismissNowPlaying
        case setShader(String?)

        /// App launch: rehydrate settings, load the account, start the updater,
        /// and listen for system media commands.
        case onAppear

        /// "心动模式": seeds `intelligenceList` with a random liked track. Both
        /// the Home page and CarPlay send this; the guard lives here so neither
        /// has to duplicate the preconditions.
        case startHeartbeat

        /// A system Now Playing event (media keys, Control Center, lock screen,
        /// CarPlay) turned into an action the store can route.
        case nowPlaying(NowPlayingCommand)
    }

    /// Pages pushed onto the detail stack.
    @Reducer
    public enum Path {
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

    @Dependency(\.nowPlaying) public var nowPlaying
    @Dependency(\.playback) public var playback
    @Dependency(\.intelligence) public var intelligence

    public var body: some ReducerOf<Self> {
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
                guard !state.isAppeared else { return .none }
                state.isAppeared = true
                return .merge(
                    .send(.player(.onAppear)),
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

            case .presentNowPlaying:
                state.isNowPlayingPresented = true
                return .none

            case .dismissNowPlaying:
                state.isNowPlayingPresented = false
                return .none

            case .setShader(let id):
                state.shaderID = id
                return .none

            case let .settings(.setDisableImageLoading(disabled)):
                return .run { send in
                    guard !Task.isCancelled else { return }
                    await ImageLoadingControl.shared.setDisabled(disabled)
                    guard !Task.isCancelled else { return }
                    await send(.imageLoadingDiagnosticApplied(disabled))
                }
                .cancellable(id: "image-loading-diagnostic", cancelInFlight: true)

            case let .imageLoadingDiagnosticApplied(disabled):
                guard state.settings.disableImageLoading == disabled,
                      let track = state.player.currentTrack else { return .none }
                return .run { [playback] _ in
                    playback.updateMetadata(title: track.name, artist: track.artistNames,
                        album: track.album.name,
                        coverURL: disabled ? nil : track.album.picUrl.flatMap(URL.init(string:)))
                }

            case .settings(.setShowMainWindowAmbientBackground(true)):
                let currentID = state.shaderID
                return .run { send in
                    let id = await MainActor.run {
                        ShaderSettings.shared.enableBackdropSelection(
                            from: ShaderDiscovery.shared.availableDescriptors, currentID: currentID)
                    }
                    await send(.setShader(id))
                }

            case .clearPath:
                state.path = StackState()
                return .none

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

            // The "心动模式" card: needs the account's liked list and a seed
            // track, which only this composition root can see. CarPlay reuses
            // the same action.
            case .home(.delegate(.startHeartbeat)):
                return .send(.startHeartbeat)

            case .startHeartbeat:
                guard let likedList = state.account.likedSongsPlaylist else { return .none }
                guard let seed = state.account.likedTrackIDs.randomElement() else {
                    return .send(.toasts(.presented(String(localized: "先收藏一些喜欢的歌曲吧"))))
                }
                let playlistID = likedList.id
                return .run { [intelligence] send in
                    do {
                        let tracks = try await intelligence?.intelligenceList(
                            songID: MusicID(seed), playlistID: MusicID(playlistID)
                        ) ?? []
                        guard !tracks.isEmpty else {
                            await send(.toasts(.presented(String(localized: "心动模式暂时不可用"))))
                            return
                        }
                        await send(.player(.play(
                            tracks: tracks, source: .playlist(playlistID), startAt: nil, context: .heartbeat)))
                        await send(.toasts(.presented(String(localized: "已开启心动模式"))))
                    } catch {
                        await send(.toasts(.presented(error.localizedDescription)))
                    }
                }

            case let .player(.toast(message)):
                return .send(.toasts(.presented(message)))

            // Content pages handing the queue to the player.
            case let .playlistRoot(.delegate(.play(tracks, source, startAt, context))),
                 let .path(.element(_, .playlist(.delegate(.play(tracks, source, startAt, context))))),
                 let .path(.element(_, .radarPlaylist(.delegate(.play(tracks, source, startAt, context))))),
                 let .path(.element(_, .album(.delegate(.play(tracks, source, startAt, context))))),
                 let .path(.element(_, .artist(.delegate(.play(tracks, source, startAt, context))))):
                return .send(.player(.play(tracks: tracks, source: source, startAt: startAt, context: context)))

            case let .home(.delegate(.play(tracks, source, context))),
                 let .explore(.delegate(.play(tracks, source, context))),
                 let .daily(.delegate(.play(tracks, source, context))),
                 let .cloud(.delegate(.play(tracks, source, context))),
                 let .path(.element(_, .toplists(.delegate(.play(tracks, source, context))))),
                 let .path(.element(_, .daily(.delegate(.play(tracks, source, context))))),
                 let .path(.element(_, .cloud(.delegate(.play(tracks, source, context))))):
                return .send(.player(.play(tracks: tracks, source: source, startAt: nil, context: context)))

            // Search hands the player the row the user tapped.
            case let .search(.delegate(.play(tracks, source, startAt, context))),
                 let .path(.element(_, .search(.delegate(.play(tracks, source, startAt, context))))):
                return .send(.player(.play(tracks: tracks, source: source, startAt: startAt, context: context)))

            case let .recents(.delegate(.play(tracks, startAt, context))),
                 let .path(.element(_, .recents(.delegate(.play(tracks, startAt, context))))):
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

            case .collections(.delegate(.refreshSublists)),
                 .path(.element(_, .collections(.delegate(.refreshSublists)))):
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
                state.player.enableAudioSourceFallback = state.settings.enableAudioSourceFallback
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
    public static func pathElement(for destination: Destination) -> Path.State? {
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

extension AppFeature.Path.State: Equatable {}
extension AppFeature.Path.Action: Equatable {}
