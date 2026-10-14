import CoreImage.CIFilterBuiltins
import ComposableArchitecture
import KumoneCore
import SwiftUI

struct LoginSheet: View {
    @SwiftUI.Bindable var store: StoreOf<LoginFeature>
    let appStore: StoreOf<AppFeature>

    @State private var qrImage: PlatformImage?

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("登录网易云音乐")
                    .font(.title3.weight(.semibold))
                Picker("", selection: Binding(
                    get: { store.mode },
                    set: { store.send(.switchMode($0)) }
                )) {
                    ForEach(LoginFeature.Mode.allCases) { mode in
                        Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .padding(.top, 6)
            }
            .padding(.top, 28)

            switch store.mode {
            case .qr:
                qrSection
            case .sms:
                smsSection
            }

            Button("取消") {
                appStore.send(.dismissLogin)
            }
            .buttonStyle(.scalePress)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .padding(.bottom, 20)
        }
        .frame(width: 320)
        .onAppear {
            store.send(.onAppear)
            qrImage = store.qrLoginURL.flatMap { Self.generateQR(from: $0) }
        }
        .onDisappear {
            store.send(.dismiss)
        }
        .onChange(of: store.qrLoginURL) { _, url in
            qrImage = url.flatMap { Self.generateQR(from: $0) }
        }
        // Coming back from the NetEase app (single-device flow): if polling
        // died while we were in the background, pick it up again.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, store.mode == .qr else { return }
            if case .failed = store.phase { store.send(.onAppear) }
        }
        .onChange(of: store.mode) { _, mode in
            if mode == .qr, case .failed = store.phase { store.send(.onAppear) }
        }
    }

    // MARK: - QR

    private var qrSection: some View {
        VStack(spacing: 20) {
            Text("使用网易云音乐 App 扫码登录")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white)
                    .frame(width: 208, height: 208)
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)

                if let qrImage {
                    Image(platformImage: qrImage)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 180, height: 180)
                        .blur(radius: overlayVisible ? 3 : 0)
                } else {
                    ProgressView()
                }

                if overlayVisible {
                    VStack(spacing: 10) {
                        switch store.phase {
                        case .expired:
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(Theme.accent)
                            Text("二维码已失效")
                                .font(.system(size: 12, weight: .medium))
                            Button("刷新") {
                                store.send(.onAppear)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                            .controlSize(.small)
                        case .scanned(let nickname):
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.green)
                            Text("已扫码")
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(nickname)，请在手机上确认")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        default:
                            EmptyView()
                        }
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            Group {
                switch store.phase {
                case .loading:
                    Text("正在获取二维码…")
                case .waiting:
                    Text("打开网易云音乐 App，扫一扫登录")
                case .scanned:
                    Text("等待手机确认…")
                case .expired:
                    Text("二维码已失效，请刷新")
                case .success:
                    Text("登录成功！")
                case .failed(let message):
                    Text(message).foregroundStyle(Theme.accent)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            #if os(iOS)
            Text("只有一台设备？截图二维码，到网易云音乐 App 的扫一扫里选择相册识别，然后回到这里即可")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            #endif
        }
    }

    private var overlayVisible: Bool {
        switch store.phase {
        case .expired, .scanned: return true
        default: return false
        }
    }

    // MARK: - SMS

    private var smsSection: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                Text("可能被网易云风控拦截而不可用，推荐使用扫码登录")
                    .font(.system(size: 11.5))
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 28)

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "iphone")
                        .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 20)
                    Text("+86").font(.system(size: 15, weight: .medium))
                    Rectangle().fill(.quaternary).frame(width: 1, height: 20)
                    TextField("手机号", text: Binding(
                        get: { store.phone },
                        set: { store.send(.setPhone($0)) }
                    ))
                        .textFieldStyle(.plain).font(.system(size: 15))
                        #if os(iOS)
                        .keyboardType(.phonePad).textContentType(.telephoneNumber)
                        #endif
                }
                .fieldChrome()

                HStack(spacing: 10) {
                    TextField("验证码", text: Binding(
                        get: { store.code },
                        set: { store.send(.setCode($0)) }
                    ))
                        .textFieldStyle(.plain).font(.system(size: 15))
                        #if os(iOS)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        #endif
                    Button {
                        store.send(.sendCode)
                    } label: {
                        Group {
                            if store.isSendingCode {
                                ProgressView().controlSize(.small)
                            } else if store.smsCooldown > 0 {
                                Text("\(store.smsCooldown)s").monospacedDigit()
                            } else {
                                Text("获取验证码")
                            }
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(canSendCode ? Theme.accent : .secondary)
                    }
                    .buttonStyle(.scalePress).disabled(!canSendCode)
                }
                .fieldChrome()
            }
            .padding(.horizontal, 28)

            if let statusMessage = store.statusMessage {
                Text(statusMessage)
                    .font(.system(size: 12)).foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }

            Button {
                store.send(.loginWithCode)
            } label: {
                Group {
                    if store.isLoggingIn {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Text("登录")
                    }
                }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(
                    Capsule().fill(canLogin ? AnyShapeStyle(Theme.accentGradient)
                                            : AnyShapeStyle(Color.secondary.opacity(0.25)))
                )
            }
            .buttonStyle(.pressable).disabled(!canLogin)
            .padding(.horizontal, 28).padding(.top, 2)
        }
        .frame(minHeight: 300)
    }

    private var canSendCode: Bool { !store.isSendingCode && store.smsCooldown == 0 && store.phone.count >= 11 }
    private var canLogin: Bool { !store.isLoggingIn && store.phone.count >= 11 && store.code.count >= 4 }

    private static func generateQR(from string: String) -> PlatformImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: 180, height: 180))
        #elseif os(iOS)
        return UIImage(cgImage: cgImage)
        #endif
    }
}

private extension View {
    func fieldChrome() -> some View {
        self
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.06), lineWidth: 1))
    }
}
