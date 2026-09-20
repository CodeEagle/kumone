import ComposableArchitecture
import SwiftUI

struct DailySongsView: View {
    let store: StoreOf<DailySongsFeature>
    let appStore: StoreOf<AppFeature>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                    .padding(.horizontal, Theme.Layout.contentInset)
                    .padding(.top, 16)

                switch store.loadState {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                case let .error(message):
                    ErrorStateView(message: message) {
                        store.send(.reload)
                    }
                    .frame(minHeight: 300)
                case .loaded where store.tracks.isEmpty:
                    EmptyStateView(icon: "calendar.badge.clock", title: "暂无每日推荐",
                                   subtitle: "多听几首歌培养口味，每天 6:00 更新")
                        .frame(minHeight: 300)
                default:
                    TrackListView(
                        tracks: store.tracks,
                        recommendationContext: .daily,
                        onRecommendationReduced: { rejected, replacement in
                            store.send(.recommendationReduced(rejected: rejected, replacement: replacement))
                        },
                        onPlay: { tracks, _ in
                            store.send(.delegate(.play(tracks: tracks, source: .daily, context: .daily)))
                        },
                        appStore: appStore
                    )
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("每日推荐")
        .task {
            store.send(.onAppear)
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            CachedAsyncImage(url: store.tracks.first?.album.picUrl?.resizedImageURL(1024))
                .frame(height: 220)
                .frame(maxWidth: .infinity)
                .clipped()
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.72)],
                           startPoint: .top, endPoint: .bottom)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .font(.system(size: 26, weight: .medium))
                        Text(dateString)
                            .font(.system(size: 14, weight: .medium))
                            .opacity(0.85)
                    }
                    Text("每日推荐")
                        .font(.system(size: 30, weight: .bold))
                    Text("根据你的音乐口味 · 每天 6:00 更新")
                        .font(.system(size: 12))
                        .opacity(0.7)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)

                Spacer()

                Button {
                    store.send(.playAll)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Theme.accentGradient, in: Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                }
                .buttonStyle(.pressable)
            }
            .padding(20)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
    }

    private var dateString: String {
        let fmt = DateFormatter()
        fmt.locale = .current
        fmt.setLocalizedDateFormatFromTemplate("MMMdEEEE")
        return fmt.string(from: .now)
    }
}
