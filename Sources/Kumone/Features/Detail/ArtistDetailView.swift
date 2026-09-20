import ComposableArchitecture
import SwiftUI

struct ArtistDetailView: View {
    let store: StoreOf<ArtistDetailFeature>
    let appStore: StoreOf<AppFeature>

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var account: AccountFeature.State { appStore.account }

    private var isCompact: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: isCompact ? 16 : 26) {
                if let artist = store.artist {
                    if isCompact {
                        compactHeader(artist)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    } else {
                        regularHeader(artist)
                            .padding(.horizontal, Theme.Layout.contentInset)
                            .padding(.top, 16)
                    }

                    if !store.hotSongs.isEmpty {
                        SectionHeader(title: "热门单曲")
                            .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)

                        TrackListView(
                            tracks: store.hotSongs,
                            style: .compact,
                            onPlay: { tracks, startAt in
                                store.send(.delegate(.play(
                                    tracks: tracks,
                                    source: .artist(store.artistID),
                                    startAt: startAt,
                                    context: .artist(id: store.artistID, name: artist.name))))
                            },
                            appStore: appStore
                        )
                        .padding(.horizontal, isCompact ? 6 : Theme.Layout.contentInset - 10)
                    }

                    if !store.albums.isEmpty {
                        SectionHeader(title: "专辑")
                            .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                                ForEach(store.albums) { album in
                                    albumCard(album)
                                }
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                            }
                        }
                    }

                    if !store.epsAndSingles.isEmpty {
                        SectionHeader(title: "EP 与单曲")
                            .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                                ForEach(store.epsAndSingles) { album in
                                    albumCard(album)
                                }
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                            }
                        }
                    }

                    if !store.similar.isEmpty {
                        SectionHeader(title: "相似歌手")
                            .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                                ForEach(store.similar) { sim in
                                    Button {
                                        appStore.send(.openDestination(.artist(sim.id)))
                                    } label: {
                                        VStack(spacing: 8) {
                                            CachedAsyncImage(url: sim.picUrl?.resizedImageURL(256))
                                                .frame(width: isCompact ? 80 : 100, height: isCompact ? 80 : 100)
                                                .clipShape(Circle())
                                            Text(sim.name)
                                                .font(.system(size: 12, weight: .medium))
                                                .lineLimit(1)
                                        }
                                        .frame(width: isCompact ? 80 : 100)
                                    }
                                    .buttonStyle(.interactiveCard)
                                }
                                Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                            }
                        }
                    }
                } else if case .loading = store.loadState {
                    loadingHeader
                } else if case let .error(message) = store.loadState {
                    ErrorStateView(message: message) {
                        store.send(.reload)
                    }
                    .frame(minHeight: 400)
                }

                PlayerClearanceSpacer()
            }
        }
        #if os(macOS)
        .navigationTitle(store.artist?.name ?? String(localized: "歌手"))
        #else
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: store.artistID) {
            store.send(.onAppear)
        }
    }

    // MARK: - Compact Header

    private func compactHeader(_ artist: ArtistSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                CachedAsyncImage(url: artist.picUrl?.resizedImageURL(384))
                    .frame(width: 100, height: 100)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 5) {
                    Text(artist.name)
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(2)
                    if !artist.alias.isEmpty {
                        Text(artist.alias.joined(separator: " / "))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text("\(artist.musicSize) 首歌曲 · \(artist.albumSize) 张专辑")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            // Compact Action Bar
            HStack(spacing: 10) {
                Button {
                    store.send(.playAll)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("播放热门")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Theme.accentGradient, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                }
                .buttonStyle(.pressable)

                if account.isLoggedIn {
                    Button {
                        store.send(.toggleFollow)
                    } label: {
                        Image(systemName: store.isFollowed ? "checkmark" : "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(store.isFollowed ? Theme.accent : .primary)
                            .frame(width: 38, height: 38)
                            .background(.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }

    // MARK: - Regular Header

    private func regularHeader(_ artist: ArtistSummary) -> some View {
        HStack(alignment: .center, spacing: 28) {
            CachedAsyncImage(url: artist.picUrl?.resizedImageURL(512))
                .frame(width: 180, height: 180)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("歌手")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(artist.name)
                    .font(.largeTitle.weight(.bold))
                if !artist.alias.isEmpty {
                    Text(artist.alias.joined(separator: " / "))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Text("\(artist.musicSize) 首歌曲 · \(artist.albumSize) 张专辑")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 6)

                HStack(spacing: 10) {
                    Button {
                        store.send(.playAll)
                    } label: {
                        Label("播放热门", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Theme.accentGradient, in: Capsule())
                            .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                    }
                    .buttonStyle(.pressable)

                    if account.isLoggedIn {
                        Button {
                            store.send(.toggleFollow)
                        } label: {
                            Label(store.isFollowed ? String(localized: "已关注") : String(localized: "关注"),
                                  systemImage: store.isFollowed ? "checkmark" : "plus")
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.primary.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func albumCard(_ album: AlbumSummary) -> some View {
        Button {
            appStore.send(.openDestination(.album(album.id)))
        } label: {
            CoverCardBody(
                coverURL: album.picUrl?.resizedImageURL(384),
                title: album.name,
                subtitle: album.publishYear
            )
        }
        .buttonStyle(.interactiveCard)
    }

    private var loadingHeader: some View {
        HStack(alignment: .center, spacing: isCompact ? 14 : 24) {
            SkeletonView(cornerRadius: isCompact ? 50 : 90)
                .clipShape(Circle())
                .frame(width: isCompact ? 100 : 180, height: isCompact ? 100 : 180)

            VStack(alignment: .leading, spacing: 10) {
                SkeletonView(cornerRadius: 4).frame(maxWidth: isCompact ? 150 : 180, minHeight: 14, maxHeight: 14)
                SkeletonView(cornerRadius: 4).frame(width: 100, height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
        .padding(.top, isCompact ? 12 : 16)
    }
}
