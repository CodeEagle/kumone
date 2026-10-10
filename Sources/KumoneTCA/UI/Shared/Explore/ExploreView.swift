import ComposableArchitecture
import KumoneCore
import SwiftUI

struct ExploreView: View {
    let store: StoreOf<ExploreFeature>
    let appStore: StoreOf<AppFeature>

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                categoryChips
                    .padding(.top, 8)

                if store.selectedCategory == "排行榜" {
                    ToplistGrid(toplists: store.toplists, appStore: appStore)
                        .padding(.horizontal, Theme.Layout.contentInset)
                } else {
                    CardGrid {
                        ForEach(Array(store.playlists.enumerated()), id: \.element.id) { index, playlist in
                            Button {
                                HeroTrigger.arm(HeroID.playlist(playlist.id),
                                                sourceImageURL: playlist.coverURL?.resizedImageURL(384))
                                appStore.send(.openDestination(.playlist(playlist.id)))
                            } label: {
                                CoverCardBody(
                                    coverURL: playlist.coverURL?.resizedImageURL(384),
                                    title: playlist.name,
                                    playCount: playlist.playCount,
                                    heroID: HeroID.playlist(playlist.id)
                                ) {
                                    store.send(.playPlaylist(playlist.id))
                                }
                            }
                            .buttonStyle(.plain)
                            .staggeredAppearance(index: index % 10, id: "explore-\(playlist.id)")
                        }
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)

                    if store.loadState == .loading {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    } else if store.hasMore {
                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                store.send(.loadMore)
                            }
                    }
                }

                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("精选")
        .task {
            store.send(.onAppear)
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Spacer().frame(width: Theme.Layout.contentInset - 8)
                ForEach(ExploreFeature.categories, id: \.self) { category in
                    Button {
                        store.send(.selectCategory(category))
                    } label: {
                        Text(LocalizedStringKey(category))
                    }
                    .buttonStyle(.chip(isSelected: store.selectedCategory == category))
                }
                Spacer().frame(width: Theme.Layout.contentInset - 8)
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Toplist grid

struct ToplistGrid: View {
    let toplists: [ToplistItem]
    let appStore: StoreOf<AppFeature>

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 20)],
            alignment: .leading, spacing: 20
        ) {
            ForEach(toplists) { toplist in
                Button {
                    appStore.send(.openDestination(.playlist(toplist.id)))
                } label: {
                    HStack(spacing: 14) {
                        CachedAsyncImage(url: toplist.coverImgUrl?.resizedImageURL(256))
                            .frame(width: 110, height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(toplist.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(toplist.updateFrequency ?? "")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(toplist.tracks.prefix(3).enumerated()), id: \.offset) { i, preview in
                                    Text("\(i + 1). \(preview.first) - \(preview.second)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ToplistsView: View {
    let store: StoreOf<ToplistsFeature>
    let appStore: StoreOf<AppFeature>

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ToplistGrid(toplists: store.toplists, appStore: appStore)
                    .padding(Theme.Layout.contentInset)
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("排行榜")
        .task {
            store.send(.onAppear)
        }
    }
}
