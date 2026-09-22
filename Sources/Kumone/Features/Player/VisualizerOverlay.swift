import SwiftUI

/// The full-screen shader visualizer.
///
/// Layers `ShaderContainerView` over a deep backdrop so the shader replaces the
/// flat gradient. A picker in the corner switches between bundled shaders and
/// any `.metal` file the user has imported, and a toggle decides whether the
/// same shader also runs behind the now-playing page.
struct VisualizerOverlay: View {
    @Binding var isPresented: Bool
    let palette: ShaderPalette
    /// Called with the shader the user picked, so the caller can persist the
    /// choice for the backdrop.
    var onShaderChanged: (ShaderDescriptor?) -> Void = { _ in }

    @StateObject private var library = ShaderLibrary.shared
    @State private var selected: ShaderDescriptor?
    @State private var isImporting = false
    @State private var importMessage: String?

    /// Mirror of the caller's backdrop switch, so this toggle and the backdrop
    /// stay in step.
    @AppStorage("visualizer.backdropEnabled") private var backdropEnabled = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // The container is transparent where the shader doesn't draw, so it
            // composites over this deep backdrop rather than replacing it.
            Rectangle()
                .fill(palette.background.swiftUIColor)
                .ignoresSafeArea()

            ShaderContainerView(
                shader: selected,
                isPlaying: true,
                palette: palette
            )
            .ignoresSafeArea()

            chrome
        }
        .preferredColorScheme(.dark)
        .onAppear {
            ShaderDirectory.ensureExists()
            library.reload()
            if selected == nil {
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
            shaderPicker
            importButton
            backdropToggle
            closeButton
        }
        .padding(.top, 16)
        .padding(.trailing, 16)
    }

    private var shaderPicker: some View {
        Menu {
            ForEach(library.available) { shader in
                Button(shader.name) {
                    selected = shader
                    onShaderChanged(shader)
                }
            }
            if library.available.isEmpty {
                Text("未找到 shader")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform.circle")
                Text(selected?.name ?? "选择效果")
                    .lineLimit(1)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.12), in: Capsule())
        }
        .menuStyle(.borderlessButton)
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

// MARK: - Palette → SwiftUI

extension SIMD4 where Scalar == Float {
    /// A palette slot as an opaque SwiftUI color for the backing fill.
    var swiftUIColor: Color {
        Color(
            red: Double(x),
            green: Double(y),
            blue: Double(z),
            opacity: 1
        )
    }
}
