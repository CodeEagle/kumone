import ComposableArchitecture
import Dependencies
import Foundation

/// Login state and the user's library: profile, liked track IDs, playlists,
/// albums and artists. Replaces the `AccountStore` singleton.
@Reducer
struct AccountFeature {
    @ObservableState
    struct State: Equatable {
        var hasAuthCookie = false
        var profile: UserProfile?
        var likedTrackIDs: Set<Int> = []
        var userPlaylists: [PlaylistSummary] = []
        var likedAlbums: [AlbumSummary] = []
        var likedArtists: [ArtistSummary] = []
        var isBootstrapped = false
        var isBootstrapping = false

        var isLoggedIn: Bool { hasAuthCookie && profile != nil }
        var vipType: Int { profile?.vipType ?? 0 }

        var likedSongsPlaylist: PlaylistSummary? {
            userPlaylists.first(where: \.isLikedSongsList) ?? userPlaylists.first
        }

        var createdPlaylists: [PlaylistSummary] {
            guard let uid = profile?.userId else { return [] }
            return userPlaylists.filter { $0.creator?.userId == uid && !$0.isLikedSongsList }
        }

        var subscribedPlaylists: [PlaylistSummary] {
            guard let uid = profile?.userId else { return [] }
            return userPlaylists.filter { $0.creator?.userId != uid }
        }

        func isLiked(_ trackID: Int) -> Bool {
            likedTrackIDs.contains(trackID)
        }
    }

    enum Action: Equatable {
        /// Called at launch and after a successful login.
        case bootstrap
        case bootstrapResponse(Result<UserProfile?, AppError>)
        /// Library: playlists + liked track IDs.
        case refreshLibrary
        case libraryResponse(Result<LibraryRefresh, AppError>)
        /// Sub-collections: liked albums + followed artists.
        case refreshSublists
        case sublistsResponse(Result<SublistsRefresh, AppError>)

        case toggleLike(Int)
        case likeResponse(Result<Bool, AppError>, trackID: Int)
        /// Surfaced for the app layer to toast (login required, network failure).
        case toggleLikeFailed(AppError)

        case logout
        case logoutResponse
    }

    struct LibraryRefresh: Equatable {
        let playlists: [PlaylistSummary]
        let likedTrackIDs: [Int]
    }

    struct SublistsRefresh: Equatable {
        let albums: [AlbumSummary]
        let artists: [ArtistSummary]
    }

    @Dependency(\.netease) var api
    @Dependency(\.session) var session
    @Dependency(\.persistence) var persistence

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .bootstrap:
                guard !state.isBootstrapped else { return .none }
                state.hasAuthCookie = session.hasAuthCookie()
                guard state.hasAuthCookie else {
                    state.isBootstrapped = true
                    return .none
                }
                state.isBootstrapping = true
                let persistence = persistence
                return .run { send in
                    // Refresh the login cookie at most once per calendar day.
                    let key = "auth.lastCookieRefresh"
                    let today = Calendar.current.startOfDay(for: .now).timeIntervalSince1970
                    if persistence.doubleForKey(key) < today {
                        persistence.setDouble(today, key)
                        await api.refreshLogin()
                    }
                    do {
                        let profile = try await api.userAccount()
                        await send(.bootstrapResponse(.success(profile)))
                    } catch {
                        await send(.bootstrapResponse(.failure(AppError(wrapping: error))))
                    }
                }

            case let .bootstrapResponse(.success(profile)):
                state.profile = profile
                state.isBootstrapped = true
                state.isBootstrapping = false
                return .send(.refreshLibrary)

            case .bootstrapResponse(.failure):
                state.isBootstrapped = true
                state.isBootstrapping = false
                return .none

            case .refreshLibrary:
                guard let uid = state.profile?.userId else { return .none }
                return .run { send in
                    async let playlists = try? api.userPlaylists(uid: uid, limit: 2000, offset: 0)
                    async let liked = try? api.likedTrackIDs(uid: uid)
                    if let playlists = await playlists, let liked = await liked {
                        await send(.libraryResponse(.success(LibraryRefresh(
                            playlists: playlists, likedTrackIDs: liked
                        ))))
                    } else {
                        let message = AppError(String(localized: "加载歌单失败"))
                        await send(.libraryResponse(.failure(message)))
                    }
                }

            case let .libraryResponse(.success(refresh)):
                state.userPlaylists = refresh.playlists
                state.likedTrackIDs = Set(refresh.likedTrackIDs)
                return .none

            case .libraryResponse(.failure):
                // Keep whatever was already loaded.
                return .none

            case .refreshSublists:
                return .run { send in
                    async let albums = try? api.likedAlbums(limit: 500, offset: 0)
                    async let artists = try? api.likedArtists(limit: 500, offset: 0)
                    if let albums = await albums, let artists = await artists {
                        await send(.sublistsResponse(.success(SublistsRefresh(
                            albums: albums, artists: artists
                        ))))
                    } else {
                        let message = AppError(String(localized: "加载收藏失败"))
                        await send(.sublistsResponse(.failure(message)))
                    }
                }

            case let .sublistsResponse(.success(refresh)):
                state.likedAlbums = refresh.albums
                state.likedArtists = refresh.artists
                return .none

            case .sublistsResponse(.failure):
                return .none

            case let .toggleLike(trackID):
                guard state.isLoggedIn else {
                    return .send(.toggleLikeFailed(AppError(String(localized: "登录后即可收藏歌曲"))))
                }
                let like = !state.isLiked(trackID)
                // Optimistic update.
                if like { state.likedTrackIDs.insert(trackID) }
                else { state.likedTrackIDs.remove(trackID) }
                return .run { send in
                    do {
                        try await api.likeTrack(trackID, like)
                        await send(.likeResponse(.success(like), trackID: trackID))
                    } catch {
                        await send(.likeResponse(.failure(AppError(wrapping: error)), trackID: trackID))
                    }
                }

            case let .likeResponse(.success, trackID: _):
                return .none

            case let .likeResponse(.failure, trackID):
                // Roll back the optimistic update.
                if state.likedTrackIDs.contains(trackID) {
                    state.likedTrackIDs.remove(trackID)
                } else {
                    state.likedTrackIDs.insert(trackID)
                }
                let message = AppError(String(localized: "操作失败，请稍后重试"))
                return .send(.toggleLikeFailed(message))

            case .toggleLikeFailed:
                // The app layer turns this into a toast.
                return .none

            case .logout:
                return .run { send in
                    await api.logout()
                    await send(.logoutResponse)
                }

            case .logoutResponse:
                session.clearAuth()
                state.hasAuthCookie = false
                state.profile = nil
                state.likedTrackIDs.removeAll()
                state.userPlaylists.removeAll()
                state.likedAlbums.removeAll()
                state.likedArtists.removeAll()
                return .none
            }
        }
    }
}
