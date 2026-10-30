import CoreGraphics
import Foundation

// MARK: - Colors

public struct RGBA: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// Parses `#rgb`, `#rrggbb` or `#rrggbbaa`.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
        } else {
            self.init(Double((v >> 24) & 0xff) / 255, Double((v >> 16) & 0xff) / 255,
                      Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
        }
    }

    public var hex: String {
        String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public func with(alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }
    public var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    public static let white = RGBA(1, 1, 1)
    public static let black = RGBA(0, 0, 0)
    public static let defaultPalette: [RGBA] = [
        "#ff375f", "#ff9f0a", "#ffd60a", "#30d158", "#0a84ff", "#bf5af2", "#000000", "#ffffff",
    ].compactMap { RGBA(hex: $0) }
}

// MARK: - Annotation styles

public enum AnnotationKind: String, Codable, Sendable {
    case arrow, line, pen, highlighter, rect, ellipse, marker, text, redact, spotlight
}

public enum ArrowStyle: String, Codable, CaseIterable, Sendable { case standard, pointy, curved, double }
public enum TextFont: String, Codable, CaseIterable, Sendable { case neucha, mono, inter }
public enum TextStyle: String, Codable, CaseIterable, Sendable { case pill, plain, outline }
public enum RedactStyle: String, Codable, CaseIterable, Sendable { case pixelate, solid }
public enum SpotlightShape: String, Codable, CaseIterable, Sendable { case ellipse, rect, rounded }

/// One vector layer. A single flat struct keeps the op log trivially
/// serializable; fields irrelevant to a kind are ignored by it.
public struct Annotation: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var kind: AnnotationKind
    /// arrow/line: [tail, head]; pen/highlighter: path; marker: [center]; text: [top-left].
    public var points: [CGPoint] = []
    /// rect/ellipse/redact/spotlight frame.
    public var rect: CGRect = .zero
    /// Curved/double arrow: on-curve bend point (midpoint of the curve).
    public var bend: CGPoint?
    public var color: RGBA = RGBA(1, 0.216, 0.373)
    /// Stroke width; marker diameter; text font size.
    public var width: Double = 4
    public var filled = false
    public var cornerRadius: Double = 0
    public var arrowStyle: ArrowStyle = .standard
    public var text = ""
    public var font: TextFont = .neucha
    public var textStyle: TextStyle = .pill
    /// Explicit text box width (drag-created text); nil wraps at the canvas edge.
    public var wrapWidth: Double?
    public var redactStyle: RedactStyle = .pixelate
    public var seed: UInt64 = 1
    public var spotlightShape: SpotlightShape = .ellipse
    public var magnification: Double = 1
    public var number = 1
    /// Pen smoothing 0...6.
    public var smoothing = 3
    /// Highlighter locked straight to a text row.
    public var snapped = false

    public init(id: Int, kind: AnnotationKind) {
        self.id = id
        self.kind = kind
    }

    /// Source-based layers act on screenshot pixels and never grow the canvas.
    public var isSourceBased: Bool { kind == .redact }
}

// MARK: - Canvas / background

public enum Backdrop: String, Codable, CaseIterable, Sendable {
    case off, slate, aurora, sunset, lagoon, violet, custom, grayShadow, grayFlat

    public var isGradient: Bool { [.slate, .aurora, .sunset, .lagoon, .violet].contains(self) }
    public var isGray: Bool { self == .grayShadow || self == .grayFlat }

    public var label: String {
        switch self {
        case .off: "Off"
        case .slate: "Slate"
        case .aurora: "Aurora"
        case .sunset: "Sunset"
        case .lagoon: "Lagoon"
        case .violet: "Violet"
        case .custom: "Custom image"
        case .grayShadow: "Window gray"
        case .grayFlat: "Window gray (flat)"
        }
    }
}

public enum CanvasMode: String, Codable, CaseIterable, Sendable {
    /// Grow with a window-gray mat around layers that leave the frame.
    case framed
    /// Grow tightly, only on the sides annotations need, no mat.
    case overflow
    /// Clip everything to the screenshot frame.
    case image

    public var label: String {
        switch self {
        case .framed: "Framed"
        case .overflow: "Overflow"
        case .image: "Image"
        }
    }
}

/// A removed (or inserted) band of the source image.
public struct CutBand: Codable, Equatable, Sendable {
    public enum Axis: String, Codable, Sendable {
        /// Removes rows (a horizontal strip); later content moves up.
        case rows
        /// Removes columns (a vertical strip); later content moves left.
        case columns
    }

    public var axis: Axis
    public var start: Double
    public var end: Double
    /// Insert a transparent band of (end - start) at `start` instead of removing.
    public var insert = false

    public init(axis: Axis, start: Double, end: Double, insert: Bool = false) {
        self.axis = axis
        self.start = min(start, end)
        self.end = max(start, end)
        self.insert = insert
    }

    public var length: Double { end - start }

    /// Maps a coordinate along the band's axis through this cut.
    public func map(_ v: Double) -> Double {
        if insert { return v >= start ? v + length : v }
        if v >= end { return v - length }
        if v > start { return start }
        return v
    }

    public func map(_ p: CGPoint) -> CGPoint {
        axis == .rows ? CGPoint(x: p.x, y: map(p.y)) : CGPoint(x: map(p.x), y: p.y)
    }

    public func map(_ r: CGRect) -> CGRect {
        let a = map(CGPoint(x: r.minX, y: r.minY))
        let b = map(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }
}

// MARK: - EditOp log

public indirect enum EditOp: Codable, Equatable, Sendable {
    case add(Annotation)
    case update(Annotation)
    case remove([Int])
    case crop(CGRect)
    case background(Backdrop)
    case shadow(Bool)
    case canvas(CanvasMode)
    case cut(CutBand)
    case group([EditOp])
}

/// Everything visible in the editor, rebuilt by replaying the log.
public struct EditorState: Equatable, Sendable {
    public var annotations: [Annotation] = []
    public var crop: CGRect
    public var background: Backdrop
    public var shadow = true
    public var canvas: CanvasMode = .framed
    public var cuts: [CutBand] = []
    public var nextId = 1

    public init(crop: CGRect, background: Backdrop = .off) {
        self.crop = crop
        self.background = background
    }

    public func annotation(_ id: Int) -> Annotation? { annotations.first { $0.id == id } }

    public var nextMarkerNumber: Int {
        (annotations.filter { $0.kind == .marker }.map(\.number).max() ?? 0) + 1
    }

    mutating func apply(_ op: EditOp) {
        switch op {
        case .add(let a):
            annotations.append(a)
            nextId = max(nextId, a.id + 1)
        case .update(let a):
            if let i = annotations.firstIndex(where: { $0.id == a.id }) { annotations[i] = a }
        case .remove(let ids):
            annotations.removeAll { ids.contains($0.id) }
        case .crop(let r):
            crop = r
        case .background(let b):
            background = b
        case .shadow(let s):
            shadow = s
        case .canvas(let c):
            canvas = c
        case .cut(let band):
            cuts.append(band)
            crop = band.map(crop)
            annotations = annotations.map { Geometry.mapped($0, through: band) }
        case .group(let ops):
            ops.forEach { apply($0) }
        }
    }
}

/// The editable document: pristine source plus an undoable op log.
public struct SnapDocument: Sendable {
    public static let formatVersion = 1

    /// Untouched source pixels (full display for fresh captures).
    public var source: CGImage
    /// Pixels per logical point.
    public var scale: CGFloat
    public var initialCrop: CGRect
    public var initialBackground: Backdrop
    public private(set) var ops: [EditOp] = []
    public private(set) var cursor = 0
    public private(set) var state: EditorState

    public init(source: CGImage, scale: CGFloat, crop: CGRect? = nil, background: Backdrop = .off) {
        self.source = source
        self.scale = max(1, scale)
        let full = CGRect(x: 0, y: 0, width: CGFloat(source.width) / self.scale, height: CGFloat(source.height) / self.scale)
        self.initialCrop = crop.map { $0.intersection(full) } ?? full
        if initialCrop.isNull || initialCrop.width < 1 || initialCrop.height < 1 { initialCrop = full }
        self.initialBackground = background
        self.state = EditorState(crop: initialCrop, background: background)
    }

    public var logicalSize: CGSize {
        CGSize(width: CGFloat(source.width) / scale, height: CGFloat(source.height) / scale)
    }

    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor < ops.count }

    public mutating func push(_ op: EditOp) {
        ops.removeSubrange(cursor...)
        ops.append(op)
        cursor = ops.count
        state.apply(op)
    }

    /// Replaces the newest op (coalescing a held nudge or wheel scaling into
    /// one undo step). Falls back to push when there is nothing to amend.
    public mutating func amend(_ op: EditOp) {
        guard cursor == ops.count, !ops.isEmpty else { return push(op) }
        ops[ops.count - 1] = op
        replay()
    }

    public var lastOp: EditOp? { cursor > 0 ? ops[cursor - 1] : nil }

    public mutating func undo() {
        guard canUndo else { return }
        cursor -= 1
        replay()
    }

    public mutating func redo() {
        guard canRedo else { return }
        state.apply(ops[cursor])
        cursor += 1
    }

    public mutating func replay() {
        var s = EditorState(crop: initialCrop, background: initialBackground)
        for op in ops[0..<cursor] { s.apply(op) }
        state = s
    }

    public func allocateId() -> Int { state.nextId }

    // MARK: Serialization

    public struct Log: Codable {
        public var version: Int
        public var scale: Double
        public var crop: CGRect
        public var background: Backdrop
        public var ops: [EditOp]
        public var cursor: Int
    }

    public var log: Log {
        Log(version: Self.formatVersion, scale: scale, crop: initialCrop, background: initialBackground, ops: ops, cursor: cursor)
    }

    public init(source: CGImage, log: Log) throws {
        guard log.version == Self.formatVersion else {
            throw NSError(domain: "MacSnap", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported operation log version \(log.version)"])
        }
        self.init(source: source, scale: log.scale, crop: log.crop, background: log.background)
        ops = log.ops
        cursor = min(max(0, log.cursor), ops.count)
        replay()
    }

    public func encodedLog() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(log)
    }

    public static func decodeLog(_ data: Data) throws -> Log {
        try JSONDecoder().decode(Log.self, from: data)
    }
}
