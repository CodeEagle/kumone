import ComposableArchitecture
import KumoneCore
import SwiftUI

struct SearchView: View {
    let store: StoreOf<SearchFeature>
    let appStore: StoreOf<AppFeature>

    @State private var searchText: String

    init(store: StoreOf<SearchFeature>, appStore: StoreOf<AppFeature>) {
        self.store = store
        self.appStore = appStore
        _searchText = State(initialValue: store.query)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !store.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Picker("", selection: tabBinding) {
                        ForEach(SearchFeature.State.Tab.allCases) { tab in
                            Text(LocalizedStringKey(tab.rawValue)).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, Theme.Layout.contentInset)
                    .padding(.top, 12)

                    if store.isLoading && currentEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else if store.failedTabs.contains(store.tab) {
                        searchFailure
                    } else {
                        tabContent
                    }
                } else {
                    emptySearchPrompt
                }
                PlayerClearanceSpacer()
            }
        }
        #if os(iOS)
        // iPad enters SearchView from the sidebar, where the desktop window
        // toolbar search field is unavailable. On macOS, MainWindow owns the
        // only search field and navigates here with its submitted query.
        .searchable(text: $searchText, prompt: "搜索歌曲、歌手、专辑、歌单")
        .onSubmit(of: .search) {
            store.send(.setQuery(searchText))
        }
        .onChange(of: searchText) { _, newValue in
            store.send(.setQuery(newValue))
        }
        #endif
        .navigationTitle(store.query.isEmpty ? "搜索" : String(localized: "搜索：\(store.query)"))
        .task(id: store.tab) {
            store.send(.load)
        }
    }

    /// Shown when the current tab's load failed. The failure is not cached as
    /// an empty success, so the tab stays reloadable.
    private var searchFailure: some View {
        VStack(spacing: 12) {
            EmptyStateView(icon: "exclamationmark.triangle", title: "搜索失败", subtitle: "网络异常，请重试")
            Button("重试") { store.send(.load) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private var tabBinding: Binding<SearchFeature.State.Tab> {
        Binding(get: { store.tab }, set: { store.send(.selectTab($0)) })
    }

    private var emptySearchPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.top, 60)
            Text("探索海量华语流行与经典音乐")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("输入歌曲名称、歌手名或歌单关键字开始搜索")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    private var currentEmpty: Bool {
        switch store.tab {
        case .all: return store.songs.isEmpty && store.artists.isEmpty
        case .songs: return store.songs.isEmpty
        case .artists: return store.artists.isEmpty
        case .albums: return store.albums.isEmpty
        case .playlists: return store.playlists.isEmpty
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch store.tab {
        case .all:
            if !store.songs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "单曲") {
                        store.send(.selectTab(.songs))
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)
                    TrackListView(
                        tracks: Array(store.songs.prefix(6)),
                        onPlay: { tracks, startAt in
                            store.send(.delegate(.play(
                                tracks: tracks, source: .none, startAt: startAt, context: nil)))
                        },
                        appStore: appStore
                    )
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
            }
            if !store.artists.isEmpty {
                Shelf(title: "歌手", seeAll: { store.send(.selectTab(.artists)) }) {
                    artistCards(store.artists.prefix(8))
                }
            }
            if !store.albums.isEmpty {
                Shelf(title: "专辑", seeAll: { store.send(.selectTab(.albums)) }) {
                    albumCards(store.albums.prefix(8))
                }
            }
            if !store.playlists.isEmpty {
                Shelf(title: "歌单", seeAll: { store.send(.selectTab(.playlists)) }) {
                    playlistCards(store.playlists.prefix(8))
                }
            }
            if currentEmpty, !store.isLoading {
                EmptyStateView(icon: "magnifyingglass", title: "没有找到相关结果")
                    .frame(minHeight: 300)
            }
        case .songs:
            TrackListView(
                tracks: store.songs,
                onPlay: { tracks, startAt in
                    store.send(.delegate(.play(
                        tracks: tracks, source: .none, startAt: startAt, context: nil)))
                },
                appStore: appStore
            )
                .padding(.horizontal, Theme.Layout.contentInset - 10)
        case .artists:
            CardGrid(minWidth: 140) {
                artistCards(store.artists)
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        case .albums:
            CardGrid {
                albumCards(store.albums)
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        case .playlists:
            CardGrid {
                playlistCards(store.playlists)
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        }
    }

    private func artistCards(_ items: some Collection<ArtistSummary>) -> some View {
        ForEach(Array(items)) { artist in
            Button {
                appStore.animateOpen(.artist(artist.id))
            } label: {
                VStack(spacing: 10) {
                    CachedAsyncImage(url: artist.picUrl?.resizedImageURL(256))
                        .frame(width: 128, height: 128)
                        .clipShape(Circle())
                    Text(artist.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .frame(width: 140)
            }
            .buttonStyle(.plain)
        }
    }

    private func albumCards(_ items: some Collection<AlbumSummary>) -> some View {
        ForEach(Array(items)) { album in
            Button {
                HeroTrigger.arm(HeroID.album(album.id),
                                sourceImageURL: album.picUrl?.resizedImageURL(384))
                appStore.animateOpen(.album(album.id))
            } label: {
                CoverCardBody(
                    coverURL: album.picUrl?.resizedImageURL(384),
                    title: album.name,
                    subtitle: album.artistName,
                    heroID: HeroID.album(album.id)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func playlistCards(_ items: some Collection<PlaylistSummary>) -> some View {
        ForEach(Array(items)) { playlist in
            Button {
                HeroTrigger.arm(HeroID.playlist(playlist.id),
                                sourceImageURL: playlist.coverURL?.resizedImageURL(384))
                appStore.animateOpen(.playlist(playlist.id))
            } label: {
                CoverCardBody(
                    coverURL: playlist.coverURL?.resizedImageURL(384),
                    title: playlist.name,
                    playCount: playlist.playCount,
                    heroID: HeroID.playlist(playlist.id)
                )
            }
            .buttonStyle(.plain)
        }
    }
}
