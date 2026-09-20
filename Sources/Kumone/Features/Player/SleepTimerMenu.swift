import ComposableArchitecture
import SwiftUI

struct SleepTimerMenu: View {
    @Bindable var store: StoreOf<PlayerFeature>

    var body: some View {
        Menu {
            if let activeStatus {
                Label(activeStatus, systemImage: "timer")
                    .disabled(true)
                Divider()
            }

            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Button(String(localized: "\(minutes) 分钟")) {
                    store.send(.sleepTimer(.schedule(minutes: minutes)))
                }
                .disabled(!store.hasCurrentTrack)
            }

            Button {
                store.send(.sleepTimer(.endOfCurrentTrack))
            } label: {
                Label("当前歌曲结束时停止", systemImage: "music.note")
            }
            .disabled(!store.hasCurrentTrack)

            if store.sleepTimer.isActive {
                Divider()
                Button("取消睡眠定时", role: .destructive) {
                    store.send(.sleepTimer(.cancel))
                }
            }
        } label: {
            Label(menuTitle, systemImage: store.sleepTimer.isActive ? "timer.circle.fill" : "timer")
        }
        .disabled(!store.hasCurrentTrack && !store.sleepTimer.isActive)
    }

    private var menuTitle: String {
        switch store.sleepTimer.mode {
        case .inactive:
            return String(localized: "睡眠定时")
        case .countdown:
            return String.localizedStringWithFormat(
                String(localized: "睡眠定时（剩余 %@）"),
                remainingDuration
            )
        case .endOfCurrentTrack:
            return String(localized: "睡眠定时（本曲结束）")
        }
    }

    private var activeStatus: String? {
        switch store.sleepTimer.mode {
        case .inactive:
            return nil
        case .countdown:
            return String.localizedStringWithFormat(
                String(localized: "剩余 %@"),
                remainingDuration
            )
        case .endOfCurrentTrack:
            return String(localized: "将在当前歌曲结束时停止")
        }
    }

    private var remainingDuration: String {
        guard case .countdown(let deadline) = store.sleepTimer.mode else { return "" }
        return Formatters.duration(max(0, deadline.timeIntervalSinceNow))
    }
}
