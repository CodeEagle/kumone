import Foundation
import os

/// One logging subsystem for the whole app so `log show --predicate
/// 'subsystem == "im.missuo.Kumone"'` finds every category. The bundle id is
/// `im.missuo.Kumone`; the subsystem matches it.
public enum KumoneLogger {
    public static let subsystem = "im.missuo.Kumone"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let api = Logger(subsystem: subsystem, category: "api")
    public static let player = Logger(subsystem: subsystem, category: "player")
    public static let unblock = Logger(subsystem: subsystem, category: "unblock")
    /// Hero transitions: records source/target geometry and the PASS/FAIL
    /// verdict of every flight, so transitions can be verified without a GUI.
    public static let hero = Logger(subsystem: subsystem, category: "hero")
}

/// Appends one line to a diagnostic log file, rolling the file back to empty
/// once it passes `maxBytes`.
///
/// Probes like the shader/hero triage write every couple of seconds; without
/// a bound a long session fills the disk. Rollover loses the oldest lines —
/// diagnostics are read for recent events — and the same probe keeps writing.
public enum BoundedLogFile {
    /// Rollover size per file: 4 MiB.
    public static let defaultMaxBytes: Int64 = 4 * 1024 * 1024

    /// Appends `line` plus a newline, creating the file atomically when it
    /// does not exist yet.
    public static func append(_ line: String, to url: URL, maxBytes: Int64 = defaultMaxBytes) {
        let payload = (line + "\n").data(using: .utf8) ?? Data()
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? payload.write(to: url, options: [.atomic])
            return
        }
        defer { try? handle.close() }
        // truncate(atOffset:) moves the file pointer too, so a rollover
        // writes from the start of the file rather than at the old end.
        if let size = try? handle.seekToEnd(), size >= maxBytes {
            try? handle.truncate(atOffset: 0)
        }
        try? handle.write(contentsOf: payload)
    }
}
