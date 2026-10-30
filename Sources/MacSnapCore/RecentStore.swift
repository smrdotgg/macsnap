import CoreGraphics
import Foundation

/// The five-entry recents shelf: each entry is an editable working document
/// (pristine source + op log) plus a rendered thumbnail.
public final class RecentStore: @unchecked Sendable {
    public struct Entry: Sendable, Equatable {
        public var id: String
        public var directory: URL
        public var date: Date
        public init(id: String, directory: URL, date: Date) { self.id = id; self.directory = directory; self.date = date }
        public var thumbnailURL: URL { directory.appendingPathComponent("thumb.png") }
        public var sourceURL: URL { directory.appendingPathComponent("source.png") }
        public var logURL: URL { directory.appendingPathComponent("log.json") }
        public var metaURL: URL { directory.appendingPathComponent("meta.json") }
    }

    public struct Meta: Codable, Sendable {
        public var app: String?
        public var savedPath: String?
        public var date: Date
        public init(app: String?, savedPath: String?, date: Date) {
            self.app = app; self.savedPath = savedPath; self.date = date
        }
    }

    public let root: URL
    public let limit: Int
    private let lock = NSLock()

    public static var defaultRoot: URL {
        if let env = ProcessInfo.processInfo.environment["MACSNAP_RECENT_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: Config.expandTilde(env))
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacSnap/recent")
    }

    public init(root: URL = RecentStore.defaultRoot, limit: Int = 5) {
        self.root = root
        self.limit = limit
    }

    /// Writes (or updates) an entry. The source is written once per id; the
    /// log, thumbnail and meta are replaced every time.
    public func save(id: String, document: SnapDocument, thumbnail: CGImage?, meta: Meta) throws {
        lock.lock()
        defer { lock.unlock() }
        let dir = root.appendingPathComponent(id)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let entry = Entry(id: id, directory: dir, date: meta.date)
        if !fm.fileExists(atPath: entry.sourceURL.path) {
            try ImageFiles.writePNG(document.source, scale: document.scale, to: entry.sourceURL)
        }
        try document.encodedLog().write(to: entry.logURL, options: .atomic)
        if let thumbnail {
            try ImageFiles.writePNG(thumbnail, scale: 1, to: entry.thumbnailURL)
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(meta).write(to: entry.metaURL, options: .atomic)
        // Touch so the shelf orders by most recent activity.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
        pruneLocked()
    }

    public func list() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return listLocked()
    }

    private func listLocked() -> [Entry] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        return dirs.compactMap { d -> Entry? in
            guard fm.fileExists(atPath: d.appendingPathComponent("log.json").path),
                  fm.fileExists(atPath: d.appendingPathComponent("source.png").path) else { return nil }
            let date = (try? d.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return Entry(id: d.lastPathComponent, directory: d, date: date)
        }.sorted { $0.date > $1.date }
    }

    private func pruneLocked() {
        let all = listLocked()
        for e in all.dropFirst(limit) { try? FileManager.default.removeItem(at: e.directory) }
    }

    public func meta(_ e: Entry) -> Meta? {
        guard let d = try? Data(contentsOf: e.metaURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Meta.self, from: d)
    }

    public func load(_ e: Entry) throws -> SnapDocument {
        guard let loaded = ImageFiles.load(url: e.sourceURL) else {
            throw NSError(domain: "MacSnap", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unreadable recent source"])
        }
        let log = try SnapDocument.decodeLog(Data(contentsOf: e.logURL))
        return try SnapDocument(source: loaded.image, log: log)
    }

    public func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id))
    }
}
