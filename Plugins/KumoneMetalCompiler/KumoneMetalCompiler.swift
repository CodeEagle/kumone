import Foundation
import PackagePlugin

/// Compiles the package's Metal sources into a single `default.metallib`.
///
/// SwiftPM compiles recognized `.metal` files itself, but it offers no way to
/// put a shared header on the Metal include path, so every shader would have to
/// redeclare the host types and drift. This plugin compiles them with the
/// `include` directory on the search path and emits one library into the
/// target's resource bundle, which `ShaderLibrary` loads at runtime.
@main
struct KumoneMetalCompiler: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard target is SourceModuleTarget else {
            throw PluginError.notCompilableTarget(target.name)
        }

        let packageRoot = context.package.directoryURL
        let shadersRoot = packageRoot.appendingPathComponent("Sources/KumoneShaders")

        // Inputs: every .metal under Shaders, plus the shared header.
        let metalFiles = try collectMetalFiles(in: shadersRoot.appendingPathComponent("Shaders"))
        let header = shadersRoot.appendingPathComponent("include/KumoneShaderTypes.h")

        let outputDir = context.pluginWorkDirectoryURL
        let output = outputDir.appendingPathComponent("default.metallib")

        // Resolve the Metal compiler through xcrun. `context.tool(named:)` only
        // sees tools SwiftPM explicitly allows, and `metallib` is not among
        // them, so the toolchain is located via xcrun instead.
        let metal = try xcrunFind(tool: "metal")
        let metallib = try xcrunFind(tool: "metallib")
        // Compile each .metal to .air, then archive the .air files into a
        // .metallib. Two commands: the compile step is the one that needs the
        // include path; the archive just bundles.
        var commands: [Command] = []
        var airFiles: [URL] = []

        for source in metalFiles {
            let air = outputDir.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".air")
            airFiles.append(air)

            commands.append(
                .buildCommand(
                    displayName: "Compiling Metal shader \(source.lastPathComponent)",
                    executable: metal,
                    arguments: [
                        "-c",
                        "-target", "air64-apple-macos15.0",
                        "-I", shadersRoot.appendingPathComponent("include").path,
                        "-fmetal-math-mode=fast",
                        "-fmetal-math-fp32-functions=fast",
                        "-o", air.path,
                        source.path,
                    ],
                    inputFiles: [source, header],
                    outputFiles: [air]
                )
            )
        }

        guard !airFiles.isEmpty else {
            throw PluginError.noShaders
        }

        commands.append(
            .buildCommand(
                displayName: "Archiving default.metallib",
                executable: metallib,
                arguments: airFiles.map(\.path) + ["-o", output.path],
                inputFiles: airFiles,
                outputFiles: [output]
            )
        )

        return commands
    }
}

// MARK: - Helpers

func collectMetalFiles(in directory: URL) throws -> [URL] {
    let manager = FileManager.default
    guard let entries = try? manager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ) else {
        return []
    }
    return entries
        .filter { $0.pathExtension.lowercased() == "metal" }
        .sorted { $0.path < $1.path }
}

enum PluginError: Error {
    case notCompilableTarget(String)
    case noShaders
    case toolNotFound(String)
}

/// Resolves a tool through xcrun when it isn't visible to the plugin directly.
func xcrunFind(tool name: String) throws -> URL {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--find", name]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw PluginError.toolNotFound(name) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else {
        throw PluginError.toolNotFound(name)
    }
    return URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines))
}
