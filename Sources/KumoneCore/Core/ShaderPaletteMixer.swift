import Foundation

/// Eases the shader palette toward a new track's colours instead of snapping.
///
/// The palette is re-derived from the cover whenever the track changes, and
/// assigning it outright makes the whole backdrop jump — the exact moment the
/// user's eye is on the artwork. The mixer runs inside `draw`, so it holds the
/// palette the uniforms are actually filled with, one step per rendered frame.
///
/// Two properties matter and both are tested:
/// - **Frame-rate independence.** The step is derived from the real elapsed
///   time (`1 - exp(-dt/tau)`), not from a per-frame coefficient, so a 120Hz
///   display and a throttled 30fps window reach the same colour in the same
///   wall-clock time.
/// - **One rate for all four slots.** Easing the background faster than the
///   subject colours (or the other way round) would cross-fade through a
///   combination that never existed on the cover — a red frame on a blue
///   album. Keeping one time constant means the palette always stays a colour
///   the cover actually contained.
public struct ShaderPaletteMixer {
    /// The palette the shader is currently rendering with.
    public private(set) var current: ShaderPalette

    /// Whether `current` holds a real palette yet. The first frame has nothing
    /// to ease from — there is no previous track to fade out of — so it snaps.
    private var isSeeded: Bool

    /// Time constant of the ease, in seconds. A track change takes roughly a
    /// second to land: fast enough to feel like it belongs to the new song,
    /// slow enough that the transition reads as a dissolve rather than a blink.
    public static let tau: Float = 0.35

    /// A mixer with nothing to fade from yet: the first frame has no previous
    /// track behind it, so it snaps.
    public init() {
        self.current = .fallback
        self.isSeeded = false
    }

    /// A mixer already showing `initial`. Later steps ease away from it, which
    /// is what tests and any caller that knows its starting colour want.
    public init(startingAt initial: ShaderPalette) {
        self.current = initial
        self.isSeeded = true
    }

    /// Advances one rendered frame toward `target`.
    ///
    /// - Parameter dt: Seconds since the previous frame. Clamped, because a
    ///   window that was occluded (or a debugger pause) can hand us a huge dt
    ///   that would otherwise collapse the ease into a jump.
    public mutating func step(toward target: ShaderPalette, dt: Float) {
        guard isSeeded else {
            snap(to: target)
            return
        }
        let coefficient = Self.coefficient(for: dt)
        guard coefficient > 0 else { return }
        current = Self.lerp(current, target, coefficient)
    }

    /// Jumps straight to `palette` — used for the first frame and whenever the
    /// shader itself changes, where an ease would look like a mistake.
    public mutating func snap(to palette: ShaderPalette) {
        current = palette
        isSeeded = true
    }

    /// Exponential ease expressed as a per-step fraction, so the result depends
    /// on elapsed time rather than on how many frames were drawn.
    static func coefficient(for dt: Float, tau: Float = ShaderPaletteMixer.tau) -> Float {
        guard dt > 0, tau > 0 else { return 0 }
        // A minute-long stall (a sleeping laptop) must not become a jump either.
        let clamped = min(dt, 1.0)
        return 1 - exp(-clamped / tau)
    }

    /// Per-channel linear blend. Straight interpolation is deliberate: the four
    /// slots share a colour space, and any curved blend would dip through a
    /// different brightness on the way across.
    static func lerp(_ from: ShaderPalette, _ to: ShaderPalette, _ t: Float) -> ShaderPalette {
        ShaderPalette(
            primary: mix(from.primary, to.primary, t),
            secondary: mix(from.secondary, to.secondary, t),
            accent: mix(from.accent, to.accent, t),
            background: mix(from.background, to.background, t)
        )
    }

    private static func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        a + (b - a) * t
    }
}
