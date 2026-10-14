import ComposableArchitecture
import KumoneCore
import SwiftUI

/// 我的收藏 — liked albums and followed artists.
struct CollectionsView: View {
    let store: StoreOf<CollectionsFeature>
    let appStore: StoreOf<AppFeature>

    private enum Tab: String, CaseIterable, Identifiable {
        case albums = "专辑"
        case artists = "歌手"

        var id: String { rawValue }
    }

    @State private var tab: Tab = .albums

    private var account: AccountFeature.State { appStore.account }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(LocalizedStringKey(tab.rawValue)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .padding(.horizontal, Theme.Layout.contentInset)
                .padding(.top, 12)

                switch tab {
                case .albums:
                    if account.likedAlbums.isEmpty {
                        EmptyStateView(icon: "square.stack", title: "还没有收藏专辑")
                            .frame(minHeight: 300)
                    } else {
                        CardGrid {
                            ForEach(account.likedAlbums) { album in
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
                                .buttonStyle(.scaleCard)
                            }
                        }
                        .padding(.horizontal, Theme.Layout.contentInset)
                    }
                case .artists:
                    if account.likedArtists.isEmpty {
                        EmptyStateView(icon: "music.microphone", title: "还没有关注歌手")
                            .frame(minHeight: 300)
                    } else {
                        CardGrid(minWidth: 140) {
                            ForEach(account.likedArtists) { artist in
                                Button {
                                    HeroTrigger.arm(HeroID.artist(artist.id),
                                                    sourceImageURL: artist.picUrl?.resizedImageURL(256))
                                    appStore.animateOpen(.artist(artist.id))
                                } label: {
                                    VStack(spacing: 10) {
                                        CachedAsyncImage(url: artist.picUrl?.resizedImageURL(256))
                                            .frame(width: 128, height: 128)
                                            .modifier(CardEnvironmentPressFeedback())
                                            .heroAnchor(HeroID.artist(artist.id))
                                            .heroCardArtworkGate(heroID: HeroID.artist(artist.id))
                                            .clipShape(Circle())
                                        Text(artist.name)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 140)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.scaleCard)
                            }
                        }
                        .padding(.horizontal, Theme.Layout.contentInset)
                    }
                }
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("我的收藏")
        .task {
            store.send(.onAppear)
        }
    }
}
