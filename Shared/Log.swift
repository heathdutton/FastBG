import os

/// Everything fastbg logs, app and extension alike. State changes log at notice, so they're kept in the log store:
///   log show --last 10m --predicate 'subsystem == "com.heathdutton.fastbg"'
/// Nothing logs per frame, only the first frame after each change.
enum Log {
    static let subsystem = "com.heathdutton.fastbg"
    static let relay = Logger(subsystem: subsystem, category: "relay")
    static let sink = Logger(subsystem: subsystem, category: "sink")
    static let engine = Logger(subsystem: subsystem, category: "engine")
    static let camera = Logger(subsystem: subsystem, category: "camera")
    static let setup = Logger(subsystem: subsystem, category: "setup")
    static let library = Logger(subsystem: subsystem, category: "library")
}
