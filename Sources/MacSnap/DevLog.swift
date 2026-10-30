import Foundation

/// Plain-text developer log at ~/Library/Logs/MacSnap/macsnap.log.
/// Appends from any thread; trimmed to its newest half past 2 MB.
enum DevLog {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacSnap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("macsnap.log")
    }()

    private static let queue = DispatchQueue(label: "dev.smr.macsnap.devlog")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        let text = "\(stamp.string(from: Date())) [\(file.split(separator: "/").last ?? ""):\(line)] \(message())\n"
        queue.async {
            guard let data = text.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                let size = (try? h.seekToEnd()) ?? 0
                if size > 2 << 20, let all = try? Data(contentsOf: url) {
                    try? all.suffix(1 << 20).write(to: url, options: .atomic)
                    return write(text)
                }
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Seconds since `start`, for timing log lines.
    static func since(_ start: DispatchTime) -> String {
        String(format: "%.2fs", Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9)
    }
}
