import Foundation

/// The optional `~/.config/macsnap/macsnap.conf` INI. Every key is optional;
/// the defaults are the product.
public struct Config: Sendable {
    public enum EditorMode: String, Sendable { case overlay, window }

    public var editorMode: EditorMode = .overlay
    public var autosave = true
    public var directory: URL
    public var filename = "screenshot-{date}_{time}-{app}"
    public var palette: [RGBA] = RGBA.defaultPalette
    public var customColor = RGBA.defaultPalette[0]
    public var backgroundImage: URL?
    public var defaultBackground: Backdrop = .off
    public var previewSeconds: Double = 7
    /// Action name → key combo, e.g. "capture" → "cmd+shift+2".
    public var hotkeys: [String: String] = [
        "capture": "cmd+shift+2",
        "scroll": "cmd+shift+1",
    ]

    public static var defaultPath: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("macsnap/macsnap.conf")
    }

    public init() {
        directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Screenshots")
    }

    public static func load(from url: URL = defaultPath, environment: [String: String] = ProcessInfo.processInfo.environment) -> (Config, [String]) {
        var cfg = Config()
        var warnings: [String] = []
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            warnings = cfg.apply(ini: text)
        }
        if let dir = environment["MACSNAP_SCREENSHOT_DIR"], !dir.isEmpty {
            cfg.directory = URL(fileURLWithPath: expandTilde(dir))
        }
        return (cfg, warnings)
    }

    public static func expandTilde(_ s: String) -> String {
        (s as NSString).expandingTildeInPath
    }

    public static func parseINI(_ text: String) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        var section = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            out[section, default: [:]][key] = value
        }
        return out
    }

    @discardableResult
    public mutating func apply(ini text: String) -> [String] {
        var warnings: [String] = []
        let ini = Self.parseINI(text)
        if let e = ini["editor"] {
            if let m = e["mode"] {
                if let v = EditorMode(rawValue: m.lowercased()) { editorMode = v } else { warnings.append("editor.mode: unknown value \(m)") }
            }
        }
        if let o = ini["output"] {
            if let v = o["autosave"] { autosave = !["false", "no", "0", "off"].contains(v.lowercased()) }
            if let v = o["directory"], !v.isEmpty { directory = URL(fileURLWithPath: Self.expandTilde(v)) }
            if let v = o["filename"], !v.isEmpty {
                if v.contains("/") { warnings.append("output.filename must not contain '/'") } else { filename = v }
            }
        }
        if let c = ini["colors"] {
            if let v = c["palette"] {
                let colors = v.split(separator: ",").compactMap { RGBA(hex: String($0)) }
                if colors.isEmpty { warnings.append("colors.palette: no valid colors") } else { palette = Array(colors.prefix(8)) }
            }
            if let v = c["custom"] {
                if let col = RGBA(hex: v) { customColor = col } else { warnings.append("colors.custom: invalid color \(v)") }
            }
        }
        if let b = ini["background"] {
            if let v = b["image"], !v.isEmpty { backgroundImage = URL(fileURLWithPath: Self.expandTilde(v)) }
            if let v = b["default"] {
                switch v.lowercased() {
                case "none", "off": defaultBackground = .off
                case "gray", "window-gray": defaultBackground = .grayShadow
                default:
                    if let s = Backdrop(rawValue: v.lowercased()) { defaultBackground = s } else { warnings.append("background.default: unknown \(v)") }
                }
            }
        }
        if let p = ini["preview"], let v = p["seconds"], let s = Double(v) { previewSeconds = max(1, s) }
        if let h = ini["hotkeys"] {
            for (k, v) in h { hotkeys[k] = v }
        }
        return warnings
    }

    // MARK: Filenames

    public static func slug(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        var lastDash = false
        for ch in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch), ch.isASCII {
                out.unicodeScalars.append(ch)
                lastDash = false
            } else if !lastDash, !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// Expands `{date}`, `{time}` and `{app}`; an empty `{app}` takes one
    /// adjacent separator with it.
    public static func expand(_ pattern: String, date: Date, app: String?) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.dateFormat = "HH-mm-ss"
        var s = pattern.replacingOccurrences(of: "{date}", with: df.string(from: date))
            .replacingOccurrences(of: "{time}", with: tf.string(from: date))
        let appSlug = app.map(slug) ?? ""
        if appSlug.isEmpty {
            let seps: [Character] = ["-", "_", ".", " "]
            if let r = s.range(of: "{app}") {
                if r.lowerBound > s.startIndex, seps.contains(s[s.index(before: r.lowerBound)]) {
                    s.removeSubrange(s.index(before: r.lowerBound)..<r.upperBound)
                } else if r.upperBound < s.endIndex, seps.contains(s[r.upperBound]) {
                    s.removeSubrange(r.lowerBound...r.upperBound)
                } else {
                    s.removeSubrange(r)
                }
            }
            s = s.replacingOccurrences(of: "{app}", with: "")
        } else {
            s = s.replacingOccurrences(of: "{app}", with: appSlug)
        }
        return s.isEmpty ? "screenshot" : s
    }

    public func outputURL(date: Date = Date(), app: String?) -> URL {
        let base = Self.expand(filename, date: date, app: app)
        var url = directory.appendingPathComponent(base + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(n).png")
            n += 1
        }
        return url
    }
}
