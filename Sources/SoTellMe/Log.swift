import Foundation

/// Writes timestamped log lines to a persistent file (in addition to
/// NSLog/Console), so past errors and crashes can be reviewed after the fact
/// without needing Console.app or a live debugger attached.
enum Log {
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/SoTellMe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SoTellMe.log")
    }()

    private static let queue = DispatchQueue(label: "com.nicolasgoujon.sotellme.log")

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        write("INFO", message)
    }

    static func error(_ message: String) {
        write("ERROR", message)
    }

    private static func write(_ level: String, _ message: String) {
        NSLog("SoTellMe: \(message)")
        let line = "[\(formatter.string(from: Date()))] [\(level)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// Installs handlers so uncaught exceptions and fatal signals (crashes)
    /// get a line in our own log before the process dies, complementing the
    /// full crash report macOS already writes to
    /// ~/Library/Logs/DiagnosticReports.
    static func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            Log.error("Uncaught exception: \(exception.name.rawValue) — \(exception.reason ?? "?")\n\(exception.callStackSymbols.joined(separator: "\n"))")
        }
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig, sotellmeSignalHandler)
        }
    }
}

private func sotellmeSignalHandler(_ sig: Int32) {
    Log.error("Fatal signal \(sig) — full crash report in ~/Library/Logs/DiagnosticReports")
    signal(sig, SIG_DFL)
    raise(sig)
}
