import Foundation
import KumoneCore
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

        do {
            // Accessing security-scoped resources on iOS requires the start/stop
            // dance; harmless on macOS.
            let didStart = source.startAccessingSecurityScopedResource()
            defer { if didStart { source.stopAccessingSecurityScopedResource() } }

            // The installer copies through a temporary sibling file and only
            // replaces the destination once the copy has fully succeeded, so a
            // failure can never leave the user with a missing shader.
            let installed = try ShaderInstaller.install(source, into: directory)
            ShaderLibrary.shared.reload()

            isImporting = false
            onResult(.success(installed.deletingPathExtension().lastPathComponent))
        } catch {
            isImporting = false
            onResult(.failure(.copyFailed(error.localizedDescription)))
        }
    }
}

// MARK: - File installation

enum ShaderInstaller {
    /// Copies `source` into `directory` under its own name, atomically replacing
    /// whatever is already there.
    ///
    /// The copy lands in a temporary file next to the destination first and
    /// only swaps into place once it has fully succeeded, so a failed import
    /// never deletes a shader the user already had. Errors are thrown rather
    /// than swallowed, and a source that already lives at the destination is
    /// left untouched.
    static func install(_ source: URL, into directory: URL) throws -> URL {
        let destination = directory.appendingPathComponent(source.lastPathComponent)

        // Picking a file that is already installed: nothing to do. Returning
        // success without a copy also avoids deleting the only copy the user
        // has when source and destination resolve to the same path.
        if source.standardizedFileURL.path == destination.standardizedFileURL.path {
            return destination
        }

        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Temporaries live in the destination folder so the final move is a
        // same-directory rename, and they are hidden so a crash mid-import
        // cannot leave a stray entry for the shader scanner to pick up.
        var temporary = directory.appendingPathComponent(".kumone-import-\(UUID().uuidString).tmp")
        while temporary.standardizedFileURL.path == source.standardizedFileURL.path {
            temporary = directory.appendingPathComponent(".kumone-import-\(UUID().uuidString).tmp")
        }

        do {
            try manager.copyItem(at: source, to: temporary)

            // `replaceItemAt` is atomic and handles the "nothing there yet"
            // case, so this is the only mutation of the destination.
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } catch {
            // Never leave the leftovers of a failed import behind.
            try? manager.removeItem(at: temporary)
            throw error
        }

        return destination
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
            return String(localized: "没有选择文件")
        case .notMetalFile:
            return String(localized: "请选择 .metal 文件")
        case .cancelled:
            return String(localized: "已取消导入")
        case .directoryUnavailable:
            return String(localized: "无法访问 Shader 目录")
        case .copyFailed(let detail):
            return String(localized: "导入失败：\(detail)")
        }
    }
}
