import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Imports a user-supplied `.metal` file into the shaders directory.
///
/// macOS: an open panel limited to `.metal`. iOS: a document picker, since the
/// app is sandboxed and can only reach files the user explicitly hands it.
/// Either way the picked file is copied into `ShaderDirectory.url` and the
/// library is told to rescan, so the new shader appears in the picker without a
/// restart.
struct ShaderImporter: View {
    /// Set while an import is in flight, so the host can show a spinner.
    @Binding var isImporting: Bool
    /// Reports what happened, for a toast or alert.
    var onResult: (Result<String, ImportError>) -> Void

    @State private var isPresentingPicker = false

    var body: some View {
        Button {
            isPresentingPicker = true
        } label: {
            Label("导入 Shader…", systemImage: "square.and.arrow.down")
        }
        .fileImporter(
            isPresented: $isPresentingPicker,
            allowedContentTypes: [.sourceCode],
            allowsMultipleSelection: false
        ) { result in
            handle(result: result)
        }
    }

    private func handle(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "metal" }) else {
                onResult(.failure(.notMetalFile))
                return
            }
            importFile(url)
        case .failure:
            onResult(.failure(.cancelled))
        }
    }

    private func importFile(_ source: URL) {
        isImporting = true

        guard let directory = ShaderDirectory.url else {
            isImporting = false
            onResult(.failure(.directoryUnavailable))
            return
        }
        ShaderDirectory.ensureExists()

        let destination = directory.appendingPathComponent(source.lastPathComponent)

        // A shader of the same name already there: overwrite. The user picked
        // the file, so the newer version is the one they want.
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }

        do {
            // Accessing security-scoped resources on iOS requires the start/stop
            // dance; harmless on macOS.
            let didStart = source.startAccessingSecurityScopedResource()
            defer { if didStart { source.stopAccessingSecurityScopedResource() } }

            try FileManager.default.copyItem(at: source, to: destination)
            ShaderLibrary.shared.invalidate()
            ShaderLibrary.shared.reload()

            isImporting = false
            onResult(.success(destination.deletingPathExtension().lastPathComponent))
        } catch {
            isImporting = false
            onResult(.failure(.copyFailed(error.localizedDescription)))
        }
    }
}

// MARK: - Errors

enum ImportError: LocalizedError {
    case noFileSelected
    case notMetalFile
    case cancelled
    case directoryUnavailable
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .noFileSelected:
            return "没有选择文件"
        case .notMetalFile:
            return "请选择 .metal 文件"
        case .cancelled:
            return "已取消导入"
        case .directoryUnavailable:
            return "无法访问 Shader 目录"
        case .copyFailed(let detail):
            return "导入失败：\(detail)"
        }
    }
}
