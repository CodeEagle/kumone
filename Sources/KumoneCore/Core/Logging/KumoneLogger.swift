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
