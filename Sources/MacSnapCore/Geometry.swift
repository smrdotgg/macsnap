import CoreGraphics
import Foundation

public extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
    var length: CGFloat { hypot(x, y) }
    func distance(to p: CGPoint) -> CGFloat { hypot(p.x - x, p.y - y) }
    func mid(_ p: CGPoint) -> CGPoint { CGPoint(x: (x + p.x) / 2, y: (y + p.y) / 2) }
}

public extension CGRect {
    init(_ a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    var center: CGPoint { CGPoint(x: midX, y: midY) }
    var integralOutward: CGRect { CGRect(x: floor(minX), y: floor(minY), width: ceil(maxX) - floor(minX), height: ceil(maxY) - floor(minY)) }
}

/// Eight resize handles plus endpoint handles for lines/arrows.
public enum Handle: Hashable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    case start, end, bend

    public static let frame: [Handle] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]

    public func point(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .top: CGPoint(x: r.midX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        default: r.center
        }
    }

    public var isCorner: Bool { [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(self) }

    /// Moves the dragged edges of `r` to `p`, keeping the opposite edges fixed.
    public func resize(_ r: CGRect, to p: CGPoint, keepAspect: Bool = false) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch self {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        default: break
        }
        var out = CGRect(CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY))
        if keepAspect, r.width > 0, r.height > 0, isCorner {
            let aspect = r.width / r.height
            let w = max(out.width, out.height * aspect)
            let h = w / aspect
            let anchor = Handle.opposite(self).point(in: r)
            let dx: CGFloat = (p.x >= anchor.x) ? 1 : -1
            let dy: CGFloat = (p.y >= anchor.y) ? 1 : -1
            out = CGRect(anchor, CGPoint(x: anchor.x + dx * w, y: anchor.y + dy * h))
        }
        return out
    }

    public static func opposite(_ h: Handle) -> Handle {
        switch h {
        case .topLeft: .bottomRight
        case .top: .bottom
        case .topRight: .bottomLeft
        case .right: .left
        case .bottomRight: .topLeft
        case .bottom: .top
        case .bottomLeft: .topRight
        case .left: .right
        default: h
        }
    }
}

public enum Geometry {
    // MARK: Pen smoothing

    /// Moving-average then Catmull-Rom densification; level 0 keeps the raw path.
    public static func smoothed(_ pts: [CGPoint], level: Int) -> [CGPoint] {
        guard level > 0, pts.count > 2 else { return pts }
        let window = level * 2
        var avg: [CGPoint] = []
        avg.reserveCapacity(pts.count)
        for i in pts.indices {
            let lo = max(0, i - window), hi = min(pts.count - 1, i + window)
            // Endpoints stay pinned so the stroke starts and ends where drawn.
            let span = min(i - lo, hi - i)
            var sx: CGFloat = 0, sy: CGFloat = 0
            for j in (i - span)...(i + span) { sx += pts[j].x; sy += pts[j].y }
            let n = CGFloat(2 * span + 1)
            avg.append(CGPoint(x: sx / n, y: sy / n))
        }
        // Drop near-duplicate points before spline evaluation.
        var simple: [CGPoint] = [avg[0]]
        for p in avg.dropFirst() where p.distance(to: simple.last!) > 0.75 { simple.append(p) }
        if simple.last != avg.last { simple.append(avg.last!) }
        guard simple.count > 2 else { return simple }
        var out: [CGPoint] = []
        for i in 0..<(simple.count - 1) {
            let p0 = simple[max(0, i - 1)], p1 = simple[i], p2 = simple[i + 1], p3 = simple[min(simple.count - 1, i + 2)]
            for s in 0..<4 {
                let t = CGFloat(s) / 4, t2 = t * t, t3 = t2 * t
                let x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
                let y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
                out.append(CGPoint(x: x, y: y))
            }
        }
        out.append(simple.last!)
        return out
    }

    // MARK: Curves

    /// Quadratic control point whose curve passes through `bend` at t = 0.5.
    public static func quadControl(_ a: CGPoint, _ b: CGPoint, bend: CGPoint) -> CGPoint {
        CGPoint(x: 2 * bend.x - (a.x + b.x) / 2, y: 2 * bend.y - (a.y + b.y) / 2)
    }

    public static func defaultBend(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let m = a.mid(b)
        let d = b - a
        let len = max(1, d.length)
        // Bow to the left of travel by ~18% of the length.
        let n = CGPoint(x: d.y / len, y: -d.x / len)
        return m + n * (len * 0.18)
    }

    public static func quadPoint(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }

    public static func bendPoint(_ a: Annotation) -> CGPoint? {
        guard a.kind == .arrow, a.arrowStyle == .curved || a.arrowStyle == .double, a.points.count >= 2 else { return nil }
        return a.bend ?? defaultBend(a.points[0], a.points[1])
    }

    // MARK: Frames and bounds

    /// The editable frame used for selection handles.
    public static func frame(_ a: Annotation) -> CGRect {
        switch a.kind {
        case .rect, .ellipse, .redact, .spotlight:
            return a.rect.standardized
        case .text:
            return TextLayout.box(a)
        case .marker:
            let c = a.points.first ?? .zero
            return CGRect(x: c.x - a.width / 2, y: c.y - a.width / 2, width: a.width, height: a.width)
        case .arrow, .line, .pen, .highlighter:
            var pts = a.points
            if let b = bendPoint(a) { pts.append(b) }
            guard let f = pts.first else { return .zero }
            return pts.dropFirst().reduce(CGRect(origin: f, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
    }

    /// Visual extent including stroke widths and arrow heads.
    public static func bounds(_ a: Annotation) -> CGRect {
        let f = frame(a)
        switch a.kind {
        case .rect, .ellipse:
            return a.filled ? f : f.insetBy(dx: -a.width / 2, dy: -a.width / 2)
        case .spotlight:
            return f.insetBy(dx: -a.width, dy: -a.width)
        case .redact, .text:
            return f
        case .marker:
            return f.insetBy(dx: -2, dy: -2)
        case .arrow:
            let head = AnnotationGeometry.headLength(a)
            return f.insetBy(dx: -head, dy: -head)
        case .line, .pen:
            return f.insetBy(dx: -a.width / 2 - 1, dy: -a.width / 2 - 1)
        case .highlighter:
            return f.insetBy(dx: -a.width / 2 - 1, dy: -a.width / 2 - 1)
        }
    }

    // MARK: Hit testing

    public static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let d = b - a
        let len2 = d.x * d.x + d.y * d.y
        guard len2 > 0 else { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * d.x + (p.y - a.y) * d.y) / len2))
        return p.distance(to: CGPoint(x: a.x + t * d.x, y: a.y + t * d.y))
    }

    public static func distance(_ p: CGPoint, toPolyline pts: [CGPoint]) -> CGFloat {
        guard pts.count > 1 else { return pts.first.map { p.distance(to: $0) } ?? .infinity }
        var best = CGFloat.infinity
        for i in 0..<(pts.count - 1) { best = min(best, distance(p, toSegment: pts[i], pts[i + 1])) }
        return best
    }

    public static func curvePoints(_ a: Annotation) -> [CGPoint] {
        guard a.points.count >= 2 else { return a.points }
        if let bend = bendPoint(a) {
            let c = quadControl(a.points[0], a.points[1], bend: bend)
            return (0...24).map { quadPoint(a.points[0], c, a.points[1], CGFloat($0) / 24) }
        }
        return a.points
    }

    public static func hitTest(_ a: Annotation, _ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch a.kind {
        case .arrow, .line:
            return distance(p, toPolyline: curvePoints(a)) <= tolerance + a.width / 2 + (a.kind == .arrow ? 2 : 0)
        case .pen, .highlighter:
            return distance(p, toPolyline: a.points) <= tolerance + a.width / 2
        case .rect:
            let r = a.rect.standardized
            if a.filled { return r.insetBy(dx: -tolerance, dy: -tolerance).contains(p) }
            let outer = r.insetBy(dx: -(tolerance + a.width / 2), dy: -(tolerance + a.width / 2))
            let inner = r.insetBy(dx: tolerance + a.width / 2, dy: tolerance + a.width / 2)
            return outer.contains(p) && !(inner.width > 0 && inner.height > 0 && inner.contains(p))
        case .ellipse:
            let r = a.rect.standardized
            guard r.width > 0, r.height > 0 else { return false }
            let nx = (p.x - r.midX) / (r.width / 2), ny = (p.y - r.midY) / (r.height / 2)
            let d = sqrt(nx * nx + ny * ny)
            if a.filled { return d <= 1 + tolerance / max(1, min(r.width, r.height) / 2) }
            let band = (tolerance + a.width / 2) / max(1, min(r.width, r.height) / 2)
            return abs(d - 1) <= band
        case .spotlight, .redact, .text, .marker:
            return frame(a).insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    // MARK: Transforms

    public static func mapPoints(_ a: Annotation, _ f: (CGPoint) -> CGPoint) -> Annotation {
        var out = a
        out.points = a.points.map(f)
        if let b = a.bend { out.bend = f(b) }
        if a.rect != .zero || [.rect, .ellipse, .redact, .spotlight].contains(a.kind) {
            let p1 = f(CGPoint(x: a.rect.minX, y: a.rect.minY))
            let p2 = f(CGPoint(x: a.rect.maxX, y: a.rect.maxY))
            out.rect = CGRect(p1, p2)
        }
        return out
    }

    public static func translated(_ a: Annotation, by d: CGPoint) -> Annotation {
        mapPoints(a) { $0 + d }
    }

    public static func mapped(_ a: Annotation, through cut: CutBand) -> Annotation {
        mapPoints(a) { cut.map($0) }
    }

    /// Uniform scale about the frame center (mouse-wheel scaling).
    public static func scaled(_ a: Annotation, by k: CGFloat) -> Annotation {
        let c = frame(a).center
        var out: Annotation
        switch a.kind {
        case .text:
            out = a
            out.width = max(6, min(400, a.width * k))
            if let w = a.wrapWidth { out.wrapWidth = max(30, w * k) }
            return out
        case .marker:
            out = a
            out.width = max(12, min(300, a.width * k))
            return out
        default:
            out = mapPoints(a) { CGPoint(x: c.x + ($0.x - c.x) * k, y: c.y + ($0.y - c.y) * k) }
            return out
        }
    }

    /// Affinely maps the annotation from frame `from` into frame `to`.
    public static func refit(_ a: Annotation, from: CGRect, to: CGRect) -> Annotation {
        switch a.kind {
        case .text:
            var out = a
            out.points = [CGPoint(x: to.minX, y: to.minY)]
            if from.width > 0 { out.wrapWidth = max(30, to.width) }
            return out
        case .marker:
            var out = a
            out.points = [to.center]
            out.width = max(12, min(to.width, to.height))
            return out
        default:
            let sx = from.width > 0.0001 ? to.width / from.width : 1
            let sy = from.height > 0.0001 ? to.height / from.height : 1
            return mapPoints(a) { p in
                CGPoint(x: to.minX + (p.x - from.minX) * sx, y: to.minY + (p.y - from.minY) * sy)
            }
        }
    }

    /// Snaps `p` to 45° increments around `origin`.
    public static func snap45(_ p: CGPoint, origin: CGPoint) -> CGPoint {
        let d = p - origin
        let ang = atan2(d.y, d.x)
        let step = CGFloat.pi / 4
        let a = (ang / step).rounded() * step
        let len = d.length
        return CGPoint(x: origin.x + cos(a) * len, y: origin.y + sin(a) * len)
    }
}

/// Arrow dimensions shared by bounds, hit testing, and drawing.
public enum AnnotationGeometry {
    public static func headLength(_ a: Annotation) -> CGFloat {
        max(12, a.width * 3.6)
    }

    public static func headHalfWidth(_ a: Annotation) -> CGFloat {
        max(7, a.width * 2.2)
    }
}
