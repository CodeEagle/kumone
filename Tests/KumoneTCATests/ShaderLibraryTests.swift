import XCTest

@testable import KumoneCore
@testable import KumoneTCA

final class ShaderLibraryTests: XCTestCase {

    @MainActor
    func testBundledShadersAreDiscovered() throws {
        let library = ShaderLibrary.shared
        library.reload()

        // The bundled presets should always be present on every platform
        // this test runs on; an empty list means the metallib isn't in the
        // bundle and every visualizer would open to a black screen.
        if library.available.isEmpty {
            // Report where the loader looked, since an empty list means the
            // metallib isn't reachable and every visualizer opens to black.
            var paths = Bundle(for: ShaderBundleToken.self)
                .paths(forResourcesOfType: "bundle", inDirectory: nil)
            paths.append(Bundle(for: ShaderBundleToken.self).bundlePath)
            print("SHADER DIAGNOSTICS: no shaders found; bundles: \(paths)")
        }
        XCTAssertFalse(library.available.isEmpty, "No bundled shaders were found")

        let names = library.available.filter { $0.origin == .bundled }.map(\.name)
        XCTAssertEqual(names, ["Animated_loop", "Color_panels",
                                 "Dot_orbit", "Dot_shape",
                                 "Ink_smoke", "Metaballs", "Neuro_noise",
                                 "Simplex_noise", "Smoke_ring",
                                 "Swirl", "Voronoi"])
    }

    @MainActor
    func testBundledShaderCompilesAndExposesEntry() throws {
        let library = ShaderLibrary.shared
        library.reload()

        let swirl = try XCTUnwrap(library.available.first { $0.name == "Swirl" })
        let compiled = ShaderDiscovery.shared.library(for: swirl)

        XCTAssertNotNil(compiled, "The bundled Swirl shader failed to compile")

        let entryName = ShaderDiscovery.shared.fragmentFunctionName(for: swirl)
        XCTAssertEqual(entryName, "kumone_fragment_swirl")
    }

    @MainActor
    func testHostVertexStageIsLoadable() throws {
        let library = ShaderLibrary.shared
        library.reload()

        let host = ShaderDescriptor(id: "bundled.__host__", name: "__host__", origin: .bundled)
        let compiled = ShaderDiscovery.shared.library(for: host)
        let vertex = compiled?.makeFunction(name: "kumone_vertex")

        XCTAssertNotNil(vertex, "The shared vertex stage is missing from the library")
    }

    @MainActor
    func testNamingRoundTrips() {
        XCTAssertEqual(ShaderNaming.displayName(fragmentFunction: "kumone_fragment_swirl"), "Swirl")
        XCTAssertEqual(ShaderNaming.fragmentFunction(for: "Swirl"), "kumone_fragment_swirl")
        XCTAssertEqual(ShaderNaming.userFragmentFunction, "kumone_fragment")
    }

    @MainActor
    func testUserFileNaming() {
        // User files name their own entry point; the host looks it up by the
        // fixed name rather than deriving one from the file's name.
        XCTAssertEqual(ShaderNaming.userFragmentFunction, "kumone_fragment")
        XCTAssertEqual(ShaderNaming.fragmentFunction(for: "Swirl"),
                       "kumone_fragment_swirl")
    }
}
