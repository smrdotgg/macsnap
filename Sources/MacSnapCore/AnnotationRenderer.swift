import AppKit
import CoreGraphics

/// Draws single vector layers into a y-down context in source coordinates.
public enum AnnotationRenderer {
    public static func draw(_ a: Annotation, in ctx: CGContext, editingText: Bool = false) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch a.kind {
        case .arrow: drawArrow(a, ctx)
        case .line: drawLine(a, ctx)
        case .pen: drawPen(a, ctx)
        case .highlighter: drawHighlighter(a, ctx)
        case .rect, .ellipse: drawShape(a, ctx)
        case .marker: drawMarker(a, ctx)
        case .text: drawText(a, ctx, glyphs: !editingText)
        case .redact, .spotlight: break // drawn by CaptureRenderer with source access
        }
    }

    // MARK: Lines and arrows

    static func drawLine(_ a: Annotation, _ ctx: CGContext) {
        guard a.points.count >= 2 else { return }
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setLineWidth(a.width)
        ctx.setLineCap(.round)
        ctx.move(to: a.points[0])
        ctx.addLine(to: a.points[1])
        ctx.strokePath()
    }

    static func arrowHead(tip: CGPoint, dir: CGPoint, _ a: Annotation) -> CGPath {
        let len = AnnotationGeometry.headLength(a)
        let hw = AnnotationGeometry.headHalfWidth(a)
        let n = CGPoint(x: -dir.y, y: dir.x)
        let base = tip - dir * len
        let notch = tip - dir * (len * 0.78)
        let p = CGMutablePath()
        p.move(to: tip)
        p.addLine(to: base + n * hw)
        p.addLine(to: notch)
        p.addLine(to: base - n * hw)
        p.closeSubpath()
        return p
    }

    static func unit(_ d: CGPoint) -> CGPoint {
        let l = d.length
        return l > 0.0001 ? CGPoint(x: d.x / l, y: d.y / l) : CGPoint(x: 1, y: 0)
    }

    static func drawArrow(_ a: Annotation, _ ctx: CGContext) {
        guard a.points.count >= 2 else { return }
        let tail = a.points[0], tip = a.points[1]
        ctx.setFillColor(a.color.cgColor)
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setLineWidth(a.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let headLen = AnnotationGeometry.headLength(a)

        switch a.arrowStyle {
        case .standard:
            let dir = unit(tip - tail)
            let shaftEnd = tip - dir * min(headLen * 0.7, max(0, (tip - tail).length - 1))
            ctx.move(to: tail)
            ctx.addLine(to: shaftEnd)
            ctx.strokePath()
            ctx.addPath(arrowHead(tip: tip, dir: dir, a))
            ctx.fillPath()

        case .pointy:
            let dir = unit(tip - tail)
            let n = CGPoint(x: -dir.y, y: dir.x)
            let total = (tip - tail).length
            let neck = tip - dir * min(headLen * 1.1, total * 0.6)
            let tailW = max(0.75, a.width * 0.2)
            let neckW = max(2, a.width * 0.9)
            let hw = AnnotationGeometry.headHalfWidth(a) * 1.15
            let p = CGMutablePath()
            p.move(to: tail + n * tailW)
            p.addLine(to: neck + n * neckW)
            p.addLine(to: neck + n * hw)
            p.addLine(to: tip)
            p.addLine(to: neck - n * hw)
            p.addLine(to: neck - n * neckW)
            p.addLine(to: tail - n * tailW)
            p.addArc(center: tail, radius: tailW, startAngle: atan2(-n.y, -n.x), endAngle: atan2(n.y, n.x), clockwise: false)
            p.closeSubpath()
            ctx.addPath(p)
            ctx.fillPath()

        case .curved, .double:
            let bend = Geometry.bendPoint(a) ?? tail.mid(tip)
            let c = Geometry.quadControl(tail, tip, bend: bend)
            let samples = (0...64).map { Geometry.quadPoint(tail, c, tip, CGFloat($0) / 64) }
            let trim = headLen * 0.7
            var startIdx = 0, endIdx = samples.count - 1
            while endIdx > 1, samples[endIdx].distance(to: tip) < trim { endIdx -= 1 }
            if a.arrowStyle == .double {
                while startIdx < endIdx - 1, samples[startIdx].distance(to: tail) < trim { startIdx += 1 }
            }
            ctx.move(to: a.arrowStyle == .double ? samples[startIdx] : tail)
            for p in samples[(startIdx + 1)...endIdx] { ctx.addLine(to: p) }
            ctx.strokePath()
            // Heads follow the curve's tangent (derivative of the quadratic).
            let endDir = unit(tip - c)
            ctx.addPath(arrowHead(tip: tip, dir: endDir, a))
            ctx.fillPath()
            if a.arrowStyle == .double {
                let startDir = unit(tail - c)
                ctx.addPath(arrowHead(tip: tail, dir: startDir, a))
                ctx.fillPath()
            }
        }
    }

    // MARK: Freehand

    static func drawPen(_ a: Annotation, _ ctx: CGContext) {
        let pts = Geometry.smoothed(a.points, level: a.smoothing)
        guard let first = pts.first else { return }
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if pts.count == 1 {
            ctx.fillEllipse(in: CGRect(x: first.x - a.width / 2, y: first.y - a.width / 2, width: a.width, height: a.width))
            return
        }
        ctx.move(to: first)
        for p in pts.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
    }

    static func drawHighlighter(_ a: Annotation, _ ctx: CGContext) {
        let pts = a.snapped ? a.points : Geometry.smoothed(a.points, level: 2)
        guard let first = pts.first else { return }
        ctx.setBlendMode(.multiply)
        ctx.setStrokeColor(a.color.with(alpha: 0.42).cgColor)
        ctx.setLineWidth(a.width)
        ctx.setLineCap(a.snapped ? .butt : .round)
        ctx.setLineJoin(.round)
        ctx.move(to: first)
        if pts.count == 1 { ctx.addLine(to: first + CGPoint(x: 0.1, y: 0)) }
        for p in pts.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
    }

    // MARK: Shapes

    public static func shapePath(_ a: Annotation) -> CGPath {
        let r = a.rect.standardized
        switch a.kind {
        case .ellipse:
            return CGPath(ellipseIn: r, transform: nil)
        default:
            let rad = min(a.cornerRadius, min(r.width, r.height) / 2)
            if rad > 0.5 { return CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) }
            return CGPath(rect: r, transform: nil)
        }
    }

    static func drawShape(_ a: Annotation, _ ctx: CGContext) {
        ctx.addPath(shapePath(a))
        if a.filled {
            ctx.setFillColor(a.color.cgColor)
            ctx.fillPath()
        } else {
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.width)
            ctx.setLineJoin(a.kind == .rect && a.cornerRadius < 0.5 ? .miter : .round)
            ctx.strokePath()
        }
    }

    // MARK: Marker

    static func drawMarker(_ a: Annotation, _ ctx: CGContext) {
        let r = Geometry.frame(a)
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(a.color.cgColor)
        ctx.fillEllipse(in: r)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        ctx.setLineWidth(max(1.5, r.width * 0.07))
        ctx.strokeEllipse(in: r.insetBy(dx: r.width * 0.035, dy: r.width * 0.035))
        let light = a.color.luminance > 0.62
        let font = NSFont.systemFont(ofSize: r.width * (a.number >= 10 ? 0.46 : 0.56), weight: .bold)
        let str = NSAttributedString(string: "\(a.number)", attributes: [
            .font: font,
            .foregroundColor: light ? NSColor(white: 0.08, alpha: 1) : NSColor.white,
        ])
        withFlippedNSContext(ctx) {
            let s = str.size()
            str.draw(at: CGPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
        }
    }

    // MARK: Text

    public static func pillColors(_ a: Annotation) -> (fill: RGBA, border: RGBA) {
        // A cream pill under light ink would be unreadable; flip it dark.
        if a.color.luminance > 0.8 { return (RGBA(0.11, 0.11, 0.13), RGBA(1, 1, 1, 0.12)) }
        return (TextLayout.pillColor, RGBA(0, 0, 0, 0.12))
    }

    static func drawText(_ a: Annotation, _ ctx: CGContext, glyphs: Bool) {
        let box = TextLayout.box(a)
        if a.textStyle == .pill {
            let rad = min(box.height / 2, a.width * 0.55)
            let path = CGPath(roundedRect: box, cornerWidth: rad, cornerHeight: rad, transform: nil)
            let colors = pillColors(a)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 4, color: CGColor(gray: 0, alpha: 0.28))
            ctx.addPath(path)
            ctx.setFillColor(colors.fill.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(path)
            ctx.setStrokeColor(colors.border.cgColor)
            ctx.setLineWidth(0.75)
            ctx.strokePath()
        }
        guard glyphs else { return }
        let pad = TextLayout.padding(a)
        let str = TextLayout.attributed(a)
        let textRect = box.insetBy(dx: pad.width, dy: pad.height)
        withFlippedNSContext(ctx) {
            if a.textStyle == .outline {
                // Stroke first, then fill on top so the outline sits outside the glyphs.
                let m = NSMutableAttributedString(attributedString: str)
                m.addAttribute(.strokeWidth, value: 6.0 * max(1, a.width / 28), range: NSRange(location: 0, length: m.length))
                m.addAttribute(.strokeColor, value: NSColor(cgColor: TextLayout.outlineColor(a).cgColor)!, range: NSRange(location: 0, length: m.length))
                m.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
                let fill = NSMutableAttributedString(attributedString: str)
                fill.removeAttribute(.strokeWidth, range: NSRange(location: 0, length: fill.length))
                fill.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            } else {
                str.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
        }
    }

    public static func withFlippedNSContext(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
}
