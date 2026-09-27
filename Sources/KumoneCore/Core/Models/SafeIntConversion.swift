import Foundation

extension Double {
    /// Converts this `Double` to `Int` without trapping.
    ///
    /// Fractional values are truncated toward zero, matching `Int`'s usual
    /// conversion semantics. Values that cannot be represented as an `Int` —
    /// NaN, infinity, and anything outside `Int`'s range, e.g. `1e30` from a
    /// decoded play count — return `fallback` (0 by default) instead of
    /// trapping, which a surrounding `try?` cannot catch.
    ///
    /// - Parameter fallback: The value returned for out-of-range input.
    /// - Returns: The truncated integer, or `fallback`.
    public func safeIntValue(or fallback: Int = 0) -> Int {
        guard isFinite else { return fallback }
        let truncated = rounded(.towardZero)
        guard truncated >= Double(Int.min), truncated < Double(Int.max) else { return fallback }
        return Int(exactly: truncated) ?? fallback
    }
}
