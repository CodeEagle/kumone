import KumoneCore
import SwiftUI

/// The full-screen shader visualizer.
///
/// Layers `ShaderContainerView` over a deep backdrop so the shader replaces the
/// flat gradient. A picker in the corner switches between bundled shaders and
/// any `.metal` file the user has imported, and a toggle decides whether the
/// same shader also runs behind the now-playing page.
struct VisualizerOverlay: View {
    private static let focusVeilOpacity: Double = 0.12

    @Binding var isPresented: Bool
    let palette: ShaderPalette
    /// Called with the shader the user picked, so the caller can persist the
    /// choice for the backdrop.
    var onShaderChanged: (ShaderDescriptor?) -> Void = { _ in }

    @StateObject private var library = ShaderLibrary.shared
    /// The PCM-sync switch lives in the shader list, but it governs this
    /// overlay's own renderer too, so both sides observe the same object.
    @ObservedObject private var settings = ShaderSettings.shared
    @State private var selected: ShaderDescriptor?
    @State private var hasPicked = false
    @State private var isShaderPickerPresented = false
    @State private var isImporting = false
    @State private var importMessage: String?

    /// Mirror of the caller's backdrop switch, so this toggle and the backdrop
    /// stay in step.
    @AppStorage("visualizer.backdropEnabled") private var backdropEnabled = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // A neutral backdrop adds no colors unrelated to the cover where
            // the shader container is transparent.
            Rectangle()
                .fill(Color.black)
                .ignoresSafeArea()

            ShaderContainerView(
                shader: selected,
                isPlaying: true,
                palette: palette,
                pcmSync: settings.pcmSyncEnabled
            )
            .ignoresSafeArea()

            // A faint black veil keeps the moving visuals from overpowering the controls.
            Color.black.opacity(Self.focusVeilOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            chrome
        }
        .preferredColorScheme(.dark)
        .onAppear {
            ShaderDirectory.ensureExists()
            library.reload()
            if selected == nil && !hasPicked {
                selected = library.available.first
                onShaderChanged(selected)
            }
        }
        .overlay(alignment: .bottom) {
            if let message = importMessage {
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
                    .task {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation { importMessage = nil }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: importMessage)
    }

    private var chrome: some View {
        HStack(spacing: 10) {
            ShaderPickerButton(isPresented: $isShaderPickerPresented, selected: selected, library: library, palette: palette) { shader in
                hasPicked = true
                selected = shader
                onShaderChanged(shader)
            }
            importButton
            backdropToggle
            closeButton
        }
        .padding(.top, 16)
        .padding(.trailing, 16)
    }

    private var importButton: some View {
        ShaderImporter(isImporting: $isImporting) { result in
            switch result {
            case .success(let name):
                library.reload()
                selected = library.available.first { $0.name == name }
                onShaderChanged(selected)
                importMessage = "已导入 \(name)"
            case .failure(let error):
                importMessage = error.errorDescription
            }
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white.opacity(0.85))
        .padding(8)
        .background(.white.opacity(0.12), in: Circle())
    }

    private var backdropToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                backdropEnabled.toggle()
            }
        } label: {
            Image(systemName: backdropEnabled ? "rectangle.fill" : "rectangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.pressable)
        .help(backdropEnabled ? "背景效果已开启" : "设为播放页背景")
    }

    private var closeButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isPresented = false
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.pressable)
    }
}

/// A shared shader menu whose selection is owned by its caller.
struct ShaderPickerButton: View {
    @Binding var isPresented: Bool
    let selected: ShaderDescriptor?
    @ObservedObject var library: ShaderLibrary
    let palette: ShaderPalette
    var onChanged: ((ShaderDescriptor?) -> Void)? = nil
    /// Same setting the overlay's renderer obeys, so the preview under a row
    /// shows what picking that row will actually look like.
    @ObservedObject private var settings = ShaderSettings.shared

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform.circle")
                Text(selected?.name ?? "无")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            shaderPickerPanel
                .preferredColorScheme(.dark)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var shaderPickerPanel: some View {
        VStack(spacing: 0) {
            pcmSyncRow
            Divider()
                .overlay(.white.opacity(0.12))
            shaderRows
        }
        .frame(width: 320)
    }

    /// Audio-reactive switch, pinned above the list: it changes every shader at
    /// once rather than picking one, so it belongs to the list's header instead
    /// of to any single row.
    private var pcmSyncRow: some View {
        Toggle(isOn: $settings.pcmSyncEnabled) {
            HStack(spacing: 8) {
                Image(systemName: settings.pcmSyncEnabled ? "waveform" : "waveform.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(settings.pcmSyncEnabled ? Theme.accent : .white.opacity(0.45))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("音频响应")
                        .font(.system(size: 13, weight: .medium))
                    Text(settings.pcmSyncEnabled ? "实时 PCM 采样驱动渲染" : "脱机渲染 · 仅内置时序")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Theme.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .help(settings.pcmSyncEnabled ? "关闭后渲染不再响应音频流" : "渲染由实时 PCM 数据驱动")
    }

    private var shaderRows: some View {
        Group {
            if library.available.isEmpty {
                Text("未找到 shader")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            Button {
                                onChanged?(nil)
                                isPresented = false
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Color.black
                                        Image(systemName: "xmark")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.55))
                                    }
                                    .frame(width: 88, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    Text("无")
                                        .font(.system(size: 13, weight: .medium))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "checkmark")
                                        .opacity(selected == nil ? 1 : 0)
                                }
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(
                                    .white.opacity(selected == nil ? 0.16 : 0.04),
                                    in: RoundedRectangle(cornerRadius: 10)
                                )
                                .contentShape(Rectangle())
                            }
                            .id("none")
                            .buttonStyle(.plain)
                            .accessibilityLabel("无效果")
                            .accessibilityAddTraits(selected == nil ? .isSelected : [])
                            ForEach(library.available) { shader in
                                Button {
                                    onChanged?(shader)
                                    isPresented = false
                                } label: {
                                    HStack(spacing: 12) {
                                        ShaderPickerPreview(shader: shader, palette: palette,
                                                             pcmSync: settings.pcmSyncEnabled)
                                        Text(shader.name)
                                            .font(.system(size: 13, weight: .medium))
                                            .lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Image(systemName: "checkmark")
                                            .opacity(selected?.id == shader.id ? 1 : 0)
                                    }
                                    .foregroundStyle(.white)
                                    .padding(8)
                                    .background(
                                        .white.opacity(selected?.id == shader.id ? 0.16 : 0.04),
                                        in: RoundedRectangle(cornerRadius: 10)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .id(shader.id)
                                .buttonStyle(.plain)
                                .accessibilityLabel(shader.name)
                                .accessibilityAddTraits(selected?.id == shader.id ? .isSelected : [])
                            }
                        }
                        .padding(10)
                    }
                    .onAppear {
                        if let id = selected?.id {
                            proxy.scrollTo(id, anchor: .center)
                        } else {
                            proxy.scrollTo("none", anchor: .center)
                        }
                    }
                }
                .frame(height: min(CGFloat(library.available.count + 1) * 78 + 14, 326))
            }
        }
    }

    /// Release offscreen Metal views even when the lazy stack retains row state.
    private struct ShaderPickerPreview: View {
        let shader: ShaderDescriptor
        let palette: ShaderPalette
        let pcmSync: Bool
        @State private var isVisible = false

        var body: some View {
            ZStack {
                Color.black
                if isVisible {
                    ShaderContainerView(shader: shader, isPlaying: true,
                                        palette: palette, pcmSync: pcmSync)
                }
            }
            .frame(width: 88, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
        }
    }
}

// MARK: - Palette → SwiftUI

extension SIMD4 where Scalar == Float {
    /// A palette slot as an opaque SwiftUI color for the backing fill.
    var swiftUIColor: Color {
        Color(
            .sRGBLinear,
            red: Double(x),
            green: Double(y),
            blue: Double(z),
            opacity: 1
        )
    }
}
