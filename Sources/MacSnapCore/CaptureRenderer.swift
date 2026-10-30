import AppKit
import CoreGraphics

/// Where everything lands in the flattened output, in logical points.
public struct RenderLayout: Equatable, Sendable {
    /// Source-coordinate region the card covers (crop, possibly grown).
    public var content: CGRect
    /// The screenshot frame inside the card (source coordinates).
    public var crop: CGRect
    /// Backdrop padding around the card.
    public var padding: CGFloat
    /// Whether framed growth added a window-gray mat around the crop.
    public var matted: Bool
    public var background: Backdrop
    public var cardShadow: Bool

    public var size: CGSize {
        CGSize(width: content.width + 2 * padding, height: content.height + 2 * padding)
    }

    /// Output-space rect of the card.
    public var cardRect: CGRect {
        CGRect(x: padding, y: padding, width: content.width, height: content.height)
    }

    /// Source → output translation.
    public var offset: CGPoint { CGPoint(x: padding - content.minX, y: padding - content.minY) }

    public var hasBackdrop: Bool { background != .off }
    public var cardRadius: CGFloat { hasBackdrop ? 10 : 0 }
}

public enum CaptureRenderer {
    public static let matGray = RGBA(0.86, 0.86, 0.88)
    public static let matMargin: CGFloat = 15

    // MARK: Layout

    public static func annotationBounds(_ state: EditorState) -> CGRect? {
        let rects = state.annotations.filter { !$0.isSourceBased }.map(Geometry.bounds)
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    public static func layout(_ state: EditorState, extra: Annotation? = nil) -> RenderLayout {
        let crop = state.crop.integralOutward
        var content = crop
        var matted = false
        var bounds = annotationBounds(state)
        if let extra, !extra.isSourceBased {
            let b = Geometry.bounds(extra)
            bounds = bounds.map { $0.union(b) } ?? b
        }
        if state.canvas != .image, let b = bounds?.integralOutward {
            let margin: CGFloat = state.canvas == .framed ? matMargin : 0
            var minX = crop.minX, minY = crop.minY, maxX = crop.maxX, maxY = crop.maxY
            if b.minX < crop.minX { minX = b.minX - margin }
            if b.minY < crop.minY { minY = b.minY - margin }
            if b.maxX > crop.maxX { maxX = b.maxX + margin }
            if b.maxY > crop.maxY { maxY = b.maxY + margin }
            content = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            matted = state.canvas == .framed && content != crop
        }
        let padding: CGFloat
        if state.background == .off {
            padding = 0
        } else {
            let m = max(content.width, content.height)
            padding = (min(80, max(28, m * 0.055))).rounded()
        }
        return RenderLayout(content: content, crop: crop, padding: padding, matted: matted,
                            background: state.background,
                            cardShadow: state.shadow && state.background != .grayFlat && state.background != .off)
    }

    // MARK: Cuts

    /// Applies cut bands, in order, to the pristine source.
    public static func composeCuts(_ source: CGImage, scale: CGFloat, cuts: [CutBand]) -> CGImage {
        var img = source
        for cut in cuts {
            let a = Int((cut.start * scale).rounded()), len = Int((cut.length * scale).rounded())
            guard len > 0 else { continue }
            let w = img.width, h = img.height
            let rows = cut.axis == .rows
            let extent = rows ? h : w
            let start = max(0, min(extent, a))
            let newExtent = cut.insert ? extent + len : max(1, extent - min(len, extent - start))
            let nw = rows ? w : newExtent, nh = rows ? newExtent : h
            guard let ctx = makeContext(width: nw, height: nh) else { continue }
            ctx.interpolationQuality = .none
            // CG's origin is bottom-left; work in y-up pixel space here.
            func draw(srcFrom: Int, srcTo: Int, dstAt: Int) {
                guard srcTo > srcFrom else { return }
                let src: CGRect, dst: CGRect
                if rows {
                    src = CGRect(x: 0, y: srcFrom, width: w, height: srcTo - srcFrom)
                    dst = CGRect(x: 0, y: nh - dstAt - (srcTo - srcFrom), width: w, height: srcTo - srcFrom)
                } else {
                    src = CGRect(x: srcFrom, y: 0, width: srcTo - srcFrom, height: h)
                    dst = CGRect(x: dstAt, y: 0, width: srcTo - srcFrom, height: h)
                }
                if let part = img.cropping(to: src) { ctx.draw(part, in: dst) }
            }
            if cut.insert {
                draw(srcFrom: 0, srcTo: start, dstAt: 0)
                draw(srcFrom: start, srcTo: extent, dstAt: start + len)
            } else {
                let end = min(extent, start + len)
                draw(srcFrom: 0, srcTo: start, dstAt: 0)
                draw(srcFrom: end, srcTo: extent, dstAt: start)
            }
            if let out = ctx.makeImage() { img = out }
        }
        return img
    }

    // MARK: Contexts

    public static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Draws `image` into `rect` of a y-down context.
    public static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    // MARK: Full render

    /// Flattens the document to native pixels, as copied and saved.
    public static func render(source composed: CGImage, scale: CGFloat, state: EditorState,
                              customBackground: CGImage? = nil) -> CGImage? {
        let lay = layout(state)
        let pw = Int((lay.size.width * scale).rounded()), ph = Int((lay.size.height * scale).rounded())
        guard let ctx = makeContext(width: pw, height: ph) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.interpolationQuality = .high
        drawScene(ctx: ctx, layout: lay, source: composed, scale: scale, state: state, customBackground: customBackground)
        return ctx.makeImage()
    }

    public struct SceneOptions {
        public var hiddenIds: Set<Int> = []
        public var live: Annotation?
        public var editingTextId: Int?
        public var drawBackdrop = true
        public init() {}
    }

    /// Draws the scene into a y-down context whose units are output points.
    public static func drawScene(ctx: CGContext, layout lay: RenderLayout, source: CGImage, scale: CGFloat,
                                 state: EditorState, customBackground: CGImage?, options: SceneOptions = SceneOptions()) {
        let out = CGRect(origin: .zero, size: lay.size)
        if options.drawBackdrop, lay.hasBackdrop {
            drawBackdrop(lay.background, in: out, ctx: ctx, custom: customBackground)
        }
        let card = lay.cardRect
        let cardPath = CGPath(roundedRect: card, cornerWidth: lay.cardRadius, cornerHeight: lay.cardRadius, transform: nil)
        if lay.cardShadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: CGColor(gray: 0, alpha: 0.45))
            ctx.addPath(cardPath)
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.clip()
        ctx.translateBy(x: lay.offset.x, y: lay.offset.y)

        if lay.matted {
            ctx.setFillColor(matGray.cgColor)
            ctx.fill(lay.content)
        } else if lay.hasBackdrop {
            // Overflow strips over a backdrop stay see-through to it; under the
            // screenshot nothing shows. Nothing to fill.
        }
        drawScreenshot(source: source, scale: scale, crop: lay.crop, ctx: ctx, shadowed: lay.matted)

        var anns = state.annotations.filter { !options.hiddenIds.contains($0.id) }
        if let live = options.live {
            if let i = anns.firstIndex(where: { $0.id == live.id }) { anns[i] = live } else { anns.append(live) }
        }

        // Redactions destroy screenshot pixels and never leave the frame.
        for a in anns where a.kind == .redact {
            ctx.saveGState()
            ctx.clip(to: lay.crop)
            drawRedaction(a, source: source, scale: scale, ctx: ctx)
            ctx.restoreGState()
        }
        let spots = anns.filter { $0.kind == .spotlight }
        if !spots.isEmpty {
            drawSpotlights(spots, area: lay.content, source: source, scale: scale, ctx: ctx)
        }
        for a in anns where a.kind != .redact && a.kind != .spotlight {
            AnnotationRenderer.draw(a, in: ctx, editingText: a.id == options.editingTextId)
        }
        ctx.restoreGState()
    }

    static func drawScreenshot(source: CGImage, scale: CGFloat, crop: CGRect, ctx: CGContext, shadowed: Bool) {
        let px = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale).integral
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let clipped = px.intersection(bounds)
        guard !clipped.isNull, let part = source.cropping(to: clipped) else { return }
        let dst = CGRect(x: clipped.minX / scale, y: clipped.minY / scale, width: clipped.width / scale, height: clipped.height / scale)
        if shadowed {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 14, color: CGColor(gray: 0, alpha: 0.35))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(dst)
            ctx.restoreGState()
        }
        drawImage(part, in: dst, ctx: ctx)
    }

    // MARK: Redaction

    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    public static func drawRedaction(_ a: Annotation, source: CGImage, scale: CGFloat, ctx: CGContext) {
        let r = a.rect.standardized
        guard r.width >= 1, r.height >= 1 else { return }
        if a.redactStyle == .solid {
            ctx.setFillColor(CGColor(srgbRed: 0.07, green: 0.07, blue: 0.07, alpha: 1))
            ctx.fill(r)
            return
        }
        // Randomized, non-spatial mosaic: block colors come from the region
        // but are shuffled, so no layout of the original survives.
        let block = max(8, min(r.width, r.height) / 5)
        let cols = max(1, Int(ceil(r.width / block))), rows = max(1, Int(ceil(r.height / block)))
        let px = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        var colors: [CGColor] = []
        if !px.isNull, px.width >= 1, px.height >= 1, let part = source.cropping(to: px),
           let small = makeContext(width: cols, height: rows) {
            small.interpolationQuality = .medium
            small.draw(part, in: CGRect(x: 0, y: 0, width: cols, height: rows))
            if let data = small.data {
                let bpr = small.bytesPerRow
                let p = data.bindMemory(to: UInt8.self, capacity: bpr * rows)
                for y in 0..<rows {
                    for x in 0..<cols {
                        let o = y * bpr + x * 4
                        let al = max(1, Double(p[o + 3])) / 255
                        colors.append(CGColor(srgbRed: Double(p[o]) / 255 / al, green: Double(p[o + 1]) / 255 / al,
                                              blue: Double(p[o + 2]) / 255 / al, alpha: 1))
                    }
                }
            }
        }
        if colors.isEmpty { colors = [CGColor(gray: 0.5, alpha: 1)] }
        var rng = SplitMix64(state: a.seed)
        colors.shuffle(using: &rng)
        let bw = r.width / CGFloat(cols), bh = r.height / CGFloat(rows)
        for y in 0..<rows {
            for x in 0..<cols {
                let c = colors[(y * cols + x) % colors.count]
                // Small brightness jitter keeps flat regions from reading as solid.
                let j = CGFloat(Int(rng.next() % 17) - 8) / 255
                let comps = c.components ?? [0.5, 0.5, 0.5, 1]
                ctx.setFillColor(CGColor(srgbRed: min(1, max(0, comps[0] + j)), green: min(1, max(0, comps[1] + j)),
                                         blue: min(1, max(0, comps[2] + j)), alpha: 1))
                ctx.fill(CGRect(x: r.minX + CGFloat(x) * bw, y: r.minY + CGFloat(y) * bh, width: bw + 0.5, height: bh + 0.5))
            }
        }
    }

    // MARK: Spotlight

    public static func spotlightPath(_ a: Annotation) -> CGPath {
        let r = a.rect.standardized
        switch a.spotlightShape {
        case .ellipse: return CGPath(ellipseIn: r, transform: nil)
        case .rect: return CGPath(rect: r, transform: nil)
        case .rounded:
            let rad = min(14, min(r.width, r.height) / 4)
            return CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
        }
    }

    public static func drawSpotlights(_ spots: [Annotation], area: CGRect, source: CGImage, scale: CGFloat, ctx: CGContext) {
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fill(area.insetBy(dx: -2000, dy: -2000))
        ctx.setBlendMode(.clear)
        for s in spots {
            ctx.addPath(spotlightPath(s))
            ctx.fillPath()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        let full = CGRect(x: 0, y: 0, width: CGFloat(source.width) / scale, height: CGFloat(source.height) / scale)
        for s in spots {
            let path = spotlightPath(s)
            if s.magnification > 1.01 {
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                let c = s.rect.standardized.center
                ctx.translateBy(x: c.x, y: c.y)
                ctx.scaleBy(x: s.magnification, y: s.magnification)
                ctx.translateBy(x: -c.x, y: -c.y)
                drawImage(source, in: full, ctx: ctx)
                ctx.restoreGState()
            }
            if s.width > 0.1 {
                ctx.saveGState()
                ctx.addPath(path)
                ctx.setStrokeColor(s.color.cgColor)
                ctx.setLineWidth(s.width)
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
    }

    // MARK: Backdrops

    struct Blob { var x: CGFloat; var y: CGFloat; var r: CGFloat; var color: RGBA }

    static func palette(_ style: Backdrop) -> (base: RGBA, blobs: [Blob]) {
        func c(_ h: String) -> RGBA { RGBA(hex: h)! }
        switch style {
        case .slate:
            return (c("#1f2937"), [Blob(x: 0.1, y: 0.1, r: 0.9, color: c("#475569")),
                                   Blob(x: 0.95, y: 0.2, r: 0.7, color: c("#334155")),
                                   Blob(x: 0.6, y: 1.0, r: 0.8, color: c("#0f172a")),
                                   Blob(x: 0.2, y: 0.9, r: 0.5, color: c("#64748b"))])
        case .aurora:
            return (c("#064e3b"), [Blob(x: 0.0, y: 0.0, r: 0.9, color: c("#14b8a6")),
                                   Blob(x: 1.0, y: 0.15, r: 0.75, color: c("#22d3ee")),
                                   Blob(x: 0.55, y: 1.0, r: 0.85, color: c("#a3e635")),
                                   Blob(x: 0.1, y: 0.95, r: 0.55, color: c("#0e7490"))])
        case .sunset:
            return (c("#9a3412"), [Blob(x: 0.0, y: 0.0, r: 0.9, color: c("#fb923c")),
                                   Blob(x: 1.0, y: 0.0, r: 0.8, color: c("#ec4899")),
                                   Blob(x: 0.3, y: 1.0, r: 0.8, color: c("#facc15")),
                                   Blob(x: 1.0, y: 1.0, r: 0.7, color: c("#be123c"))])
        case .lagoon:
            return (c("#1e3a8a"), [Blob(x: 0.0, y: 0.1, r: 0.9, color: c("#0ea5e9")),
                                   Blob(x: 1.0, y: 0.0, r: 0.8, color: c("#6366f1")),
                                   Blob(x: 0.5, y: 1.0, r: 0.8, color: c("#22d3ee")),
                                   Blob(x: 0.0, y: 1.0, r: 0.5, color: c("#1d4ed8"))])
        case .violet:
            return (c("#2e1065"), [Blob(x: 0.0, y: 0.0, r: 0.9, color: c("#8b5cf6")),
                                   Blob(x: 1.0, y: 0.1, r: 0.8, color: c("#ec4899")),
                                   Blob(x: 0.4, y: 1.0, r: 0.85, color: c("#6366f1")),
                                   Blob(x: 1.0, y: 1.0, r: 0.5, color: c("#a855f7"))])
        default:
            return (matGray, [])
        }
    }

    public static func drawBackdrop(_ style: Backdrop, in rect: CGRect, ctx: CGContext, custom: CGImage?) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: rect)
        if style.isGray || (style == .custom && custom == nil) {
            ctx.setFillColor(matGray.cgColor)
            ctx.fill(rect)
            return
        }
        if style == .custom, let img = custom {
            let iw = CGFloat(img.width), ih = CGFloat(img.height)
            let k = max(rect.width / iw, rect.height / ih)
            let dst = CGRect(x: rect.midX - iw * k / 2, y: rect.midY - ih * k / 2, width: iw * k, height: ih * k)
            drawImage(img, in: dst, ctx: ctx)
            return
        }
        let (base, blobs) = palette(style)
        ctx.setFillColor(base.cgColor)
        ctx.fill(rect)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let span = max(rect.width, rect.height)
        for b in blobs {
            let center = CGPoint(x: rect.minX + b.x * rect.width, y: rect.minY + b.y * rect.height)
            let colors = [b.color.with(alpha: 0.95).cgColor, b.color.with(alpha: 0.45).cgColor, b.color.with(alpha: 0).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.45, 1]) {
                ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: b.r * span, options: [])
            }
        }
    }
}
