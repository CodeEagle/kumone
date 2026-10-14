import Metal
import XCTest
@testable import KumoneCore

@MainActor
final class ShaderRegionBlurTests: XCTestCase {
    func testBlurSoftensEdgesWithoutTintingOrChangingOutsideRegion() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let blur = try ShaderRegionBlur(device: device)
        let input = try XCTUnwrap(blur.renderTarget(width: 128, height: 128))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
            width: 128, height: 128, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var pixels = [UInt8](repeating: 255, count: 128 * 128 * 4)
        func run(feathers: [SIMD2<Float>] = []) throws -> [UInt8] {
            // Upload through a shared texture; the render target may be private.
            let upload = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            pixels.withUnsafeBytes { upload.replace(region: MTLRegionMake2D(0, 0, 128, 128),
                mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 512) }
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
            blit.copy(from: upload, to: input)
            blit.endEncoding()
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            blur.composite(command: command, destination: pass,
                           regions: [SIMD4(0.25, 0.25, 0.5, 0.5)], feathers: feathers)
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
            var result = [UInt8](repeating: 0, count: pixels.count)
            result.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: 512,
                from: MTLRegionMake2D(0, 0, 128, 128), mipmapLevel: 0) }
            return result
        }
        let white = try run()
        XCTAssertGreaterThan(white[(64 * 128 + 64) * 4], 250)
        for y in 0..<128 { for x in 0..<64 {
            let offset = (y * 128 + x) * 4
            pixels[offset] = 0; pixels[offset + 1] = 0; pixels[offset + 2] = 0
        } }
        let edges = try run()
        let darkSide = edges[(64 * 128 + 62) * 4]
        let lightSide = edges[(64 * 128 + 65) * 4]
        XCTAssertGreaterThan(darkSide, 30, "Sharp shader edge must actually be blurred")
        XCTAssertLessThan(lightSide, 245)
        XCTAssertEqual(edges[(10 * 128 + 62) * 4], 0, "Outside the marked region remains sharp")
        XCTAssertEqual(edges[(10 * 128 + 65) * 4], 255)
        let soft = try run(feathers: [SIMD2(0.32, 0.48)])
        let ramp = [36, 44, 52, 64].map { soft[($0 * 128 + 62) * 4] }
        XCTAssertLessThan(ramp[0], edges[(36 * 128 + 62) * 4],
                          "The metadata fade must start more gently than the control fade")
        XCTAssertLessThan(ramp[0], ramp[1])
        XCTAssertLessThan(ramp[1], ramp[2])
        XCTAssertLessThan(ramp[2], ramp[3])
        XCTAssertEqual(soft[(10 * 128 + 65) * 4], 255)
    }
}
