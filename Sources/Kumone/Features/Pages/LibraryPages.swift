import ComposableArchitecture
import SwiftUI

// MARK: - 最近播放

struct RecentsView: View {
    let store: StoreOf<RecentsFeature>
    let appStore: StoreOf<AppFeature>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker("", selection: weekBinding) {
                        Text("所有时间").tag(false)
                        Text("最近一周").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)

                    Spacer()

                    Button {
                        store.send(.playAll)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Theme.accentGradient, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    .disabled(store.records.isEmpty)
                }
                .padding(.horizontal, Theme.Layout.contentInset)
                .padding(.top, 12)

                switch store.loadState {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                case .loaded where store.records.isEmpty:
                    EmptyStateView(icon: "clock", title: "暂无播放记录")
                        .frame(minHeight: 300)
                case let .error(message):
                    ErrorStateView(message: message) {
                        store.send(.reload)
                    }
                    .frame(minHeight: 300)
                default:
                    recordList
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("最近播放")
        .task {
            store.send(.onAppear)
        }
    }

    private var weekBinding: Binding<Bool> {
        Binding(get: { store.week }, set: { _ in store.send(.toggleWeek) })
    }

    private var recordList: some View {
        LazyVStack(spacing: 1) {
            ForEach(Array(store.records.enumerated()), id: \.element.song.id) { index, record in
                TrackRow(
                    track: record.song,
                    index: index + 1,
                    style: .compact,
                    trailingText: String(localized: "\(record.playCount) 次"),
                    onPlay: { store.send(.playRecord(record)) },
                    appStore: appStore
                )
            }
        }
    }
}

// MARK: - 音乐云盘

struct CloudView: View {
    let store: StoreOf<CloudFeature>
    let appStore: StoreOf<AppFeature>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    if let sizeInfo = store.sizeInfo {
                        Text(sizeInfo)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        store.send(.playAll)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Theme.accentGradient, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    .disabled(store.items.isEmpty)
                }
                .padding(.horizontal, Theme.Layout.contentInset)
                .padding(.top, 12)

                switch store.loadState {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                case .loaded where store.items.isEmpty:
                    EmptyStateView(icon: "icloud", title: "云盘还没有歌曲",
                                   subtitle: "在网易云音乐客户端上传的歌曲会出现在这里")
                        .frame(minHeight: 300)
                case let .error(message):
                    ErrorStateView(message: message) {
                        store.send(.reload)
                    }
                    .frame(minHeight: 300)
                default:
                    TrackListView(
                        tracks: store.tracks,
                        style: .compact,
                        onPlay: { tracks, _ in
                            store.send(.delegate(.play(tracks: tracks, source: .cloud, context: .cloud)))
                        },
                        appStore: appStore
                    )
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("音乐云盘")
        .task {
            store.send(.onAppear)
        }
    }
}
