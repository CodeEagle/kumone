/// Normalize external durations; invalid or overflowing values become unknown (zero).
func milliseconds(fromSeconds seconds: Int) -> Int {
    let duration = max(0, seconds)
    return duration <= Int.max / 1000 ? duration * 1000 : 0
}
