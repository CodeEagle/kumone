import Foundation
import Metal

// swift Scripts/check-original-shaders.swift [ShipSwift SWMetal directory]
// Optional source audit compares every algorithm with the supplied upstream copy.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
let presets = [
    ("AnimatedLoop", "SWAnimatedLoop", "animated_loop"),
    ("Voronoi", "SWVoronoi", "voronoi"),
    ("Metaballs", "SWMetaballs", "metaballs"),
    ("Swirl", "SWSwirl", "swirl"),
    ("ColorPanels", "SWColorPanels", "color_panels"),
    ("InkSmoke", "SWInkSmoke", "ink_smoke"),
    ("NeuroNoise", "SWNeuroNoise", "neuro_noise"),
    ("DotOrbit", "SWDotOrbit", "dot_orbit"),
    ("SimplexNoise", "SWSimplexNoise", "simplex_noise"),
    ("SmokeRing", "SWSmokeRing", "smoke_ring"),
    ("DotShape", "SWDotsPlasma", "dot_shape"),
]
func read(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}
func removeIncludes(_ source: String) -> String {
    source.replacingOccurrences(of: #"(?m)^#include .*$"#, with: "", options: .regularExpression)
}
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let header = try read(root + "/Sources/KumoneShaders/include/KumoneShaderTypes.h")
let vertex = removeIncludes(try read(root + "/Sources/KumoneShaders/Shaders/KumoneHost.metal"))
let widths = [(320, 180), (180, 320)]
for (file, upstream, entry) in presets {
    let shader = try read(root + "/Sources/KumoneShaders/Shaders/" + file + ".metal")
    if CommandLine.arguments.count > 1 {
        let original = removeIncludes(try read(CommandLine.arguments[1] + "/" + upstream + ".metal"))
            .replacingOccurrences(of: "[[ stitchable ]]", with: "static inline")
        precondition(shader.contains(original), file + ": original algorithm changed")
    }
    let library = try device.makeLibrary(source: header + vertex + removeIncludes(shader), options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "kumone_vertex")
    descriptor.fragmentFunction = library.makeFunction(name: "kumone_fragment_" + entry)
    descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm_srgb
    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    func render(_ width: Int, _ height: Int, _ time: Float, _ live: Bool) -> [UInt8] {
        let uniforms = device.makeBuffer(length: 144, options: .storageModeShared)!
        uniforms.contents().initializeMemory(as: UInt8.self, repeating: 0, count: 144)
        let floats = uniforms.contents().bindMemory(to: Float.self, capacity: 36)
        floats[0] = time
        floats[2] = Float(width); floats[3] = Float(height)
        // Change every audio, artwork and beat-copy input, keeping time/resolution fixed.
        for i in 4..<36 { floats[i] = live ? Float(i % 5) / 4 : 0 }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb,
            width: width, height: height, mipmapped: false)
        td.storageMode = .shared; td.usage = [.renderTarget]
        let texture = device.makeTexture(descriptor: td)!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = queue.makeCommandBuffer()!
        let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(uniforms, offset: 0, index: 0)
        encoder.setFragmentBuffer(uniforms, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        precondition(command.status == .completed, file + ": GPU failed")
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return pixels
    }
    for (width, height) in widths {
        var phases = Set<Data>()
        for time: Float in [0, 1, 5, 24, 100] {
            let paused = render(width, height, time, false)
            precondition(paused == render(width, height, time, true),
                file + ": playback/PCM/artwork changed original output")
            precondition(paused.enumerated().contains { $0.offset % 4 != 3 && $0.element > 0 },
                file + ": blank output")
            phases.insert(Data(paused))
        }
        precondition(phases.count > 1, file + ": animation is frozen")
    }
    print("PASS " + file + ": source parity, GPU compile, independent animation and PCM/artwork invariance")
}
