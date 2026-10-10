import ComposableArchitecture
import KumoneCore
import SwiftUI

struct HomeView: View {
    let store: StoreOf<HomeFeature>
    let appStore: StoreOf<AppFeature>

    private var account: AccountFeature.State { appStore.account }

    var body: some View {
        ScrollView {
            switch store.loadState {
            case .idle, .loading:
                loadingBody
            case let .error(message):
                ErrorStateView(message: message) {
                    store.send(.reload)
                }
                .frame(minHeight: 400)
            case .loaded:
                loadedBody
            }
        }
        .navigationTitle("推荐")
        .task(id: account.isLoggedIn) {
            KumoneLogger.api.notice(
                "HOME view task isLoggedIn=\(account.isLoggedIn, privacy: .public)"
            )
            store.send(.onAppear)
        }
    }

    private var loadingBody: some View {
        VStack(alignment: .leading, spacing: 32) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonView(cornerRadius: Theme.Radius.large)
                            .frame(width: 230, height: 132)
                    }
                }
            }
            SkeletonShelf()
            SkeletonShelf()
        }
        .padding(Theme.Layout.contentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadedBody: some View {
        LazyVStack(alignment: .leading, spacing: 34) {
            // Anonymous users go straight to recommended playlists;
            // the login entry lives in the sidebar / 我的 tab only.
            if account.isLoggedIn {
                featureCards
                    .padding(.top, 8)
            }

            if !store.recommendPlaylists.isEmpty {
                Shelf(title: "推荐歌单", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(Array(store.recommendPlaylists.prefix(12).enumerated()), id: \.element.id) { index, playlist in
                        playlistCard(playlist)
                            .staggeredAppearance(index: index, id: "home-rec-\(playlist.id)")
                    }
                }
            }

            if !store.radarPlaylists.isEmpty {
                Shelf(title: "雷达歌单", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(store.radarPlaylists) { radar in
                        Button {
                            HeroTrigger.arm(HeroID.playlist(radar.id),
                                            sourceImageURL: radar.coverURL?.resizedImageURL(384))
                            appStore.send(.openDestination(.radarPlaylist(radar.id)))
                        } label: {
                            CoverCardBody(
                                coverURL: radar.coverURL?.resizedImageURL(384),
                                title: radar.title,
                                subtitle: radar.subtitle,
                                heroID: HeroID.playlist(radar.id)
                            ) {
                                store.send(.playPlaylist(radar.id))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !store.toplists.isEmpty {
                Shelf(title: "排行榜", seeAll: nil, rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(store.toplists) { toplist in
                        Button {
                            HeroTrigger.arm(HeroID.playlist(toplist.id),
                                            sourceImageURL: toplist.coverImgUrl?.resizedImageURL(384))
                            appStore.send(.openDestination(.playlist(toplist.id)))
                        } label: {
                            toplistCard(toplist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !store.newAlbums.isEmpty {
                Shelf(title: "新碟上架", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(store.newAlbums) { album in
                        albumCard(album)
                    }
                }
            }

            if !store.topArtists.isEmpty {
                Shelf(title: "推荐歌手", rowHeight: Theme.Layout.artistShelfHeight) {
                    ForEach(store.topArtists) { artist in
                        artistCard(artist)
                    }
                }
            }

            PlayerClearanceSpacer()
        }
        .padding(.vertical, Theme.Layout.contentInset - 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Feature cards

    private var featureCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                Color.clear.frame(width: max(0, Theme.Layout.contentInset - 16), height: 1)
                if account.isLoggedIn {
                    Button {
                        appStore.send(.openDestination(.daily))
                    } label: {
                        FeatureCard(
                            title: "每日推荐",
                            subtitle: "根据你的口味生成",
                            icon: "calendar",
                            coverURL: store.dailyFirstCover?.resizedImageURL(512),
                            showsDate: true
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        appStore.send(.player(.startFM))
                    } label: {
                        FeatureCard(
                            title: "私人漫游",
                            subtitle: "从喜欢的歌开始漫游",
                            icon: "wave.3.right.circle.fill",
                            gradient: [Color(red: 0.16, green: 0.20, blue: 0.42),
                                       Color(red: 0.36, green: 0.24, blue: 0.62)]
                        )
                    }
                    .buttonStyle(.interactiveCard)

                    Button {
                        store.send(.startHeartbeat)
                    } label: {
                        FeatureCard(
                            title: "心动模式",
                            subtitle: "你的红心歌曲和相似推荐",
                            icon: "heart.circle.fill",
                            gradient: [Color(red: 0.85, green: 0.19, blue: 0.41),
                                       Color(red: 0.98, green: 0.42, blue: 0.34)]
                        )
                    }
                    .buttonStyle(.interactiveCard)
                }
                Color.clear.frame(width: max(0, Theme.Layout.contentInset - 16), height: 1)
            }
            .padding(.vertical, 6)
        }
        .compatScrollClipDisabled()
    }

    // MARK: - Cards

    private func playlistCard(_ playlist: PlaylistSummary) -> some View {
        Button {
            HeroTrigger.arm(HeroID.playlist(playlist.id),
                            sourceImageURL: playlist.coverURL?.resizedImageURL(384))
            appStore.send(.openDestination(.playlist(playlist.id)))
        } label: {
            CoverCardBody(
                coverURL: playlist.coverURL?.resizedImageURL(384),
                title: playlist.name,
                subtitle: playlist.copywriter,
                playCount: playlist.playCount,
                heroID: HeroID.playlist(playlist.id)
            ) {
                store.send(.playPlaylist(playlist.id))
            }
        }
        .buttonStyle(.plain)
    }

    private func albumCard(_ album: AlbumSummary) -> some View {
        Button {
            HeroTrigger.arm(HeroID.album(album.id),
                            sourceImageURL: album.picUrl?.resizedImageURL(384))
            appStore.send(.openDestination(.album(album.id)))
        } label: {
            CoverCardBody(
                coverURL: album.picUrl?.resizedImageURL(384),
                title: album.name,
                subtitle: album.artistName,
                heroID: HeroID.album(album.id)
            ) {
                store.send(.playAlbum(album))
            }
        }
        .buttonStyle(.plain)
    }

    private func artistCard(_ artist: ArtistSummary) -> some View {
        Button {
            HeroTrigger.arm(HeroID.artist(artist.id),
                            sourceImageURL: artist.picUrl?.resizedImageURL(256))
            appStore.send(.openDestination(.artist(artist.id)))
        } label: {
            VStack(spacing: 10) {
                CachedAsyncImage(url: artist.picUrl?.resizedImageURL(256))
                    .frame(width: 128, height: 128)
                    .clipShape(Circle())
                    .heroAnchor(HeroID.artist(artist.id))
                    .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                Text(artist.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(width: 140)
        }
        .buttonStyle(.plain)
    }

    private func toplistCard(_ toplist: ToplistItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: toplist.coverImgUrl?.resizedImageURL(384))
                    .frame(width: Theme.Layout.cardSize, height: Theme.Layout.cardSize)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                    .heroAnchor(HeroID.playlist(toplist.id))
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                Text(toplist.updateFrequency ?? "")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(8)
            }
            .frame(width: Theme.Layout.cardSize, height: Theme.Layout.cardSize)
            Text(toplist.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(width: Theme.Layout.cardSize, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Feature card

struct FeatureCard: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let icon: String
    var coverURL: URL?
    var gradient: [Color] = [Color(red: 0.75, green: 0.16, blue: 0.22),
                             Color(red: 0.95, green: 0.35, blue: 0.28)]
    var showsDate = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let coverURL {
                CachedAsyncImage(url: coverURL)
                    .frame(width: 230, height: 132)
                LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.68)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [.white.opacity(0.18), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 220)
            }

            VStack(alignment: .leading, spacing: 3) {
                ZStack {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                    if showsDate {
                        Text("\(Calendar.current.component(.day, from: .now))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(y: 3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            .padding(14)
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        }
        .frame(width: 230, height: 132)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }
}

/// Card body without its own Button wrapper (for use inside NavigationLink).
struct CoverCardBody: View {
    let coverURL: URL?
    let title: String
    var subtitle: String?
    var playCount: Int = 0
    var size: CGFloat = Theme.Layout.cardSize
    var heroID: String?
    var onPlay: (() -> Void)?

    @State private var isHovering = false
    @Environment(\.flexibleCardWidth) private var flexibleWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            anchoredArtwork
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                )
                .overlay(alignment: .topTrailing) {
                    if playCount > 0 {
                        PlayCountBadge(count: playCount)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let onPlay {
                        PlayOverlayButton(visible: isHovering, action: onPlay)
                            .padding(8)
                    }
                }

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
                .frame(maxWidth: flexibleWidth ? .infinity : size, alignment: .leading)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: flexibleWidth ? .infinity : size, alignment: .leading)
            }
        }
        .frame(maxWidth: flexibleWidth ? .infinity : size, alignment: .leading)
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
    }

    @ViewBuilder
    private var anchoredArtwork: some View {
        if let heroID {
            artwork.heroAnchor(heroID)
        } else {
            artwork
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if flexibleWidth {
            CachedAsyncImage(url: coverURL)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else {
            CachedAsyncImage(url: coverURL)
                .frame(width: size, height: size)
        }
    }
}
