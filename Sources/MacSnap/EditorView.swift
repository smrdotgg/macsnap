import AppKit
import MacSnapCore

/// The annotation canvas. The document's op log is the model; everything on
/// screen is `doc.state` plus transient "live" overrides during a gesture.
final class EditorView: NSView, NSTextViewDelegate {
    weak var controller: EditorController?
    private(set) var doc: SnapDocument
    var settings: ToolSettings
    private(set) var tool: Tool = .select
    private var toolBeforeEyedropper: Tool = .select
    private(set) var selection: Set<Int> = []
    var zoom: CGFloat = 1
    var pan: CGPoint = .zero
    let overlayMode: Bool
    var customBackground: CGImage?
    private(set) var toolbar: EditorToolbar!

    private enum Drag {
        case none
        case create(start: CGPoint, centered: Bool)
        case textBox(start: CGPoint)
        case move(start: CGPoint, originals: [Annotation], moved: Bool)
        case handle(Handle, original: Annotation, frame: CGRect)
        case crop(Handle, original: CGRect)
        case marquee(start: CGPoint)
        case pan(startView: CGPoint, startPan: CGPoint)
        case cut(start: CGPoint, insert: Bool)
        case ocr(start: CGPoint)
    }

    private var drag: Drag = .none
    private var liveOverrides: [Int: Annotation] = [:]
    private var liveNew: Annotation?
    private var liveCrop: CGRect?
    private var cutPreview: CutBand?
    private var marquee: CGRect?
    private var ocrRect: CGRect?
    private var pointer: CGPoint = .zero
    private var textRows: [CGRect] = []
    private var textRowsCuts: [CutBand]?
    private var composedCache: (cuts: [CutBand], image: CGImage)?
    private var status: String?
    private var statusWork: DispatchWorkItem?
    private var textEditor: (view: NSTextView, annotation: Annotation, isNew: Bool)?
    private(set) var cutInsertArmed = false
    private var spaceDown = false
    private var coalesce: (token: String, time: Date)?
    private var ocrPanel: OCRPanel?
    private var hideHandles = false
    private var lastClickSelectedId: Int?

    init(frame: CGRect, document: SnapDocument, settings: ToolSettings, overlay: Bool, customBackground: CGImage?) {
        doc = document
        self.settings = settings
        overlayMode = overlay
        self.customBackground = customBackground
        super.init(frame: frame)
        toolbar = EditorToolbar(editor: self)
        addSubview(toolbar)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
        refreshTextRows()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var canUndo: Bool { doc.canUndo }
    var canRedo: Bool { doc.canRedo }
    var document: SnapDocument {
        commitText(dismissAfter: false)
        return doc
    }

    // MARK: Coordinates

    func toSource(_ v: CGPoint) -> CGPoint { CGPoint(x: (v.x - pan.x) / zoom, y: (v.y - pan.y) / zoom) }
    func toView(_ s: CGPoint) -> CGPoint { CGPoint(x: s.x * zoom + pan.x, y: s.y * zoom + pan.y) }
    func toView(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * zoom + pan.x, y: r.minY * zoom + pan.y, width: r.width * zoom, height: r.height * zoom)
    }

    var composed: CGImage {
        if let c = composedCache, c.cuts == doc.state.cuts { return c.image }
        let img = CaptureRenderer.composeCuts(doc.source, scale: doc.scale, cuts: doc.state.cuts)
        composedCache = (doc.state.cuts, img)
        return img
    }

    var displayState: EditorState {
        var s = doc.state
        for (id, a) in liveOverrides {
            if let i = s.annotations.firstIndex(where: { $0.id == id }) { s.annotations[i] = a }
        }
        if let n = liveNew { s.annotations.append(n) }
        if let c = liveCrop { s.crop = c }
        return s
    }

    /// Output rect (backdrop included) in source coordinates.
    var outputRectInSource: CGRect {
        let lay = CaptureRenderer.layout(displayState)
        return CGRect(x: -lay.offset.x, y: -lay.offset.y, width: lay.size.width, height: lay.size.height)
    }

    // MARK: Placement

    /// Positions the capture where it was on screen (fresh overlay captures)
    /// or fits it into the view.
    func place(native: Bool) {
        if native {
            zoom = 1
            pan = .zero
            let out = toView(outputRectInSource)
            if !bounds.insetBy(dx: 4, dy: 4).contains(out) { fit() }
        } else {
            fit()
        }
        viewChanged()
    }

    func fit() {
        let r = outputRectInSource
        let top: CGFloat = overlayMode ? 70 : 84, bottom: CGFloat = 56, side: CGFloat = overlayMode ? 40 : 24
        let avail = CGRect(x: side, y: top, width: bounds.width - 2 * side, height: bounds.height - top - bottom)
        guard r.width > 0, r.height > 0, avail.width > 20, avail.height > 20 else { return }
        zoom = min(1, min(avail.width / r.width, avail.height / r.height))
        pan = CGPoint(x: avail.midX - r.midX * zoom, y: avail.midY - r.midY * zoom)
        viewChanged()
    }

    func setZoom(_ z: CGFloat, about v: CGPoint) {
        let nz = min(16, max(0.05, z))
        let s = toSource(v)
        zoom = nz
        pan = CGPoint(x: v.x - s.x * nz, y: v.y - s.y * nz)
        viewChanged()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionChrome()
    }

    func viewChanged() {
        positionChrome()
        needsDisplay = true
    }

    private func positionChrome() {
        guard let toolbar else { return }
        let size = toolbar.frame.size
        var origin: CGPoint
        if overlayMode {
            let card = toView(outputRectInSource)
            let topInset = window?.screen?.safeAreaInsets.top ?? 0
            origin = CGPoint(x: card.midX - size.width / 2, y: card.minY - size.height - 10)
            if origin.y < topInset + 8 {
                origin.y = card.maxY + 10
                if origin.y + size.height > bounds.height - 50 { origin.y = max(topInset + 8, card.minY + 10) }
            }
            origin.x = min(max(8, origin.x), bounds.width - size.width - 8)
        } else {
            origin = CGPoint(x: (bounds.width - size.width) / 2, y: 34)
        }
        toolbar.setFrameOrigin(CGPoint(x: origin.x.rounded(), y: origin.y.rounded()))
        if let ed = textEditor { layoutTextView(ed.view, for: ed.annotation) }
        ocrPanel.map(positionOCRPanel)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if overlayMode {
            ctx.setFillColor(Chrome.scrim.cgColor)
        } else {
            ctx.setFillColor(NSColor(calibratedWhite: 0.13, alpha: 1).cgColor)
        }
        ctx.fill(dirtyRect)

        let state = displayState
        let lay = CaptureRenderer.layout(state)
        ctx.saveGState()
        ctx.translateBy(x: pan.x, y: pan.y)
        ctx.scaleBy(x: zoom, y: zoom)
        ctx.translateBy(x: -lay.offset.x, y: -lay.offset.y)
        ctx.interpolationQuality = zoom < 1 ? .high : (zoom > 2 ? .none : .medium)
        var opts = CaptureRenderer.SceneOptions()
        opts.editingTextId = textEditor?.annotation.id
        CaptureRenderer.drawScene(ctx: ctx, layout: lay, source: composed, scale: doc.scale, state: state,
                                  customBackground: customBackground, options: opts)
        ctx.restoreGState()

        drawBoundary(ctx, crop: state.crop)
        if let band = cutPreview { drawCutPreview(ctx, band) }
        if !hideHandles {
            drawSelection(ctx, state)
            if tool == .select, selection.isEmpty, textEditor == nil { drawCropHandles(ctx, state.crop) }
        }
        if let m = marquee { drawDashed(ctx, toView(m), color: Chrome.accent) }
        if let o = ocrRect { drawDashed(ctx, toView(o), color: .systemYellow) }
        if tool == .highlighter, settings.highlighterSnap, case .none = drag, let row = row(at: toSource(pointer)) {
            let h = row.height * zoom * 1.1
            ctx.setFillColor(Chrome.accent.withAlphaComponent(0.8).cgColor)
            ctx.fill(CGRect(x: pointer.x - 1, y: toView(CGPoint(x: 0, y: row.midY)).y - h / 2, width: 2, height: h))
        }
        if tool == .eyedropper { drawEyedropperPreview() }
        drawHint()
        if !Chrome.guideHidden { drawGuide() }
    }

    private func drawDashed(_ ctx: CGContext, _ r: CGRect, color: NSColor) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
        ctx.restoreGState()
    }

    private func drawBoundary(_ ctx: CGContext, crop: CGRect) {
        let r = toView(crop).insetBy(dx: -0.5, dy: -0.5)
        ctx.saveGState()
        let bright = tool == .select
        ctx.setStrokeColor(NSColor(white: 1, alpha: bright ? 0.7 : 0.35).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [1, 3])
        ctx.stroke(r)
        ctx.restoreGState()
    }

    private func cropHandleRects(_ crop: CGRect) -> [(Handle, CGRect)] {
        let r = toView(crop)
        let o: CGFloat = 7 // handles sit outside the image
        return Handle.frame.map { h in
            let p = h.point(in: r)
            var c = p
            switch h {
            case .topLeft: c = CGPoint(x: p.x - o, y: p.y - o)
            case .top: c.y -= o
            case .topRight: c = CGPoint(x: p.x + o, y: p.y - o)
            case .right: c.x += o
            case .bottomRight: c = CGPoint(x: p.x + o, y: p.y + o)
            case .bottom: c.y += o
            case .bottomLeft: c = CGPoint(x: p.x - o, y: p.y + o)
            case .left: c.x -= o
            default: break
            }
            let horizontal = h == .top || h == .bottom
            let vertical = h == .left || h == .right
            let size = horizontal ? CGSize(width: 22, height: 5) : vertical ? CGSize(width: 5, height: 22) : CGSize(width: 9, height: 9)
            return (h, CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height))
        }
    }

    private func drawCropHandles(_ ctx: CGContext, _ crop: CGRect) {
        for (_, r) in cropHandleRects(crop) {
            let p = CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil)
            ctx.addPath(p)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.setShadow(offset: .zero, blur: 3, color: NSColor(white: 0, alpha: 0.6).cgColor)
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        }
    }

    private func handlePoints(_ a: Annotation) -> [(Handle, CGPoint)] {
        switch a.kind {
        case .arrow, .line:
            guard a.points.count >= 2 else { return [] }
            var out: [(Handle, CGPoint)] = [(.start, a.points[0]), (.end, a.points[1])]
            if let b = Geometry.bendPoint(a) { out.append((.bend, b)) }
            return out
        case .marker:
            return []
        case .text:
            let f = Geometry.frame(a)
            return [(.left, Handle.left.point(in: f)), (.right, Handle.right.point(in: f)),
                    (.topLeft, Handle.topLeft.point(in: f)), (.bottomRight, Handle.bottomRight.point(in: f))]
        default:
            let f = Geometry.frame(a)
            return Handle.frame.map { ($0, $0.point(in: f)) }
        }
    }

    private func drawSelection(_ ctx: CGContext, _ state: EditorState) {
        let accent = Chrome.accent
        for id in selection {
            guard let a = state.annotation(id) else { continue }
            let f = toView(Geometry.frame(a)).insetBy(dx: -4, dy: -4)
            if a.kind != .arrow && a.kind != .line {
                ctx.saveGState()
                ctx.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
                ctx.setLineWidth(1)
                ctx.setLineDash(phase: 0, lengths: [4, 3])
                ctx.stroke(f)
                ctx.restoreGState()
            }
            guard selection.count == 1 else { continue }
            for (h, p) in handlePoints(a) {
                let v = toView(p)
                let r = CGRect(x: v.x - 4.5, y: v.y - 4.5, width: 9, height: 9)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.setStrokeColor(accent.cgColor)
                ctx.setLineWidth(1.5)
                if h == .bend || h == .start || h == .end {
                    ctx.fillEllipse(in: r)
                    ctx.strokeEllipse(in: r)
                } else {
                    ctx.fill(r)
                    ctx.stroke(r)
                }
            }
        }
    }

    private func drawCutPreview(_ ctx: CGContext, _ band: CutBand) {
        let crop = displayState.crop
        let r: CGRect = band.axis == .rows
            ? CGRect(x: crop.minX, y: band.start, width: crop.width, height: band.length)
            : CGRect(x: band.start, y: crop.minY, width: band.length, height: crop.height)
        let v = toView(r)
        ctx.saveGState()
        let color: NSColor = band.insert ? .systemGreen : .systemRed
        ctx.setFillColor(color.withAlphaComponent(0.22).cgColor)
        ctx.fill(v)
        ctx.clip(to: v)
        if !band.insert {
            ctx.setStrokeColor(color.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(1)
            var x = v.minX - v.height
            while x < v.maxX {
                ctx.move(to: CGPoint(x: x, y: v.maxY))
                ctx.addLine(to: CGPoint(x: x + v.height, y: v.minY))
                x += 10
            }
            ctx.strokePath()
        }
        ctx.resetClip()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        if band.axis == .rows {
            ctx.move(to: CGPoint(x: v.minX - 20, y: v.minY)); ctx.addLine(to: CGPoint(x: v.maxX + 20, y: v.minY))
            ctx.move(to: CGPoint(x: v.minX - 20, y: v.maxY)); ctx.addLine(to: CGPoint(x: v.maxX + 20, y: v.maxY))
        } else {
            ctx.move(to: CGPoint(x: v.minX, y: v.minY - 20)); ctx.addLine(to: CGPoint(x: v.minX, y: v.maxY + 20))
            ctx.move(to: CGPoint(x: v.maxX, y: v.minY - 20)); ctx.addLine(to: CGPoint(x: v.maxX, y: v.maxY + 20))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawEyedropperPreview() {
        guard let c = sample(at: toSource(pointer)) else { return }
        let r = CGRect(x: pointer.x + 14, y: pointer.y + 14, width: 34, height: 34)
        let p = NSBezierPath(ovalIn: r)
        NSColor(cgColor: c.cgColor)?.setFill()
        p.fill()
        NSColor.white.setStroke()
        p.lineWidth = 2
        p.stroke()
        Chrome.drawPill(c.hex, center: CGPoint(x: r.midX, y: r.maxY + 14), font: Chrome.mono(10), padding: CGSize(width: 6, height: 3))
    }

    private var hintText: String {
        if let status { return status }
        if textEditor != nil { return "Typing · Return commits · ⇧Return new line · Esc commits and closes" }
        switch tool {
        case .select:
            if !selection.isEmpty { return "Layer selected · drag to move · handles resize · wheel scales · ⌫ deletes" }
            return "V moves layers · outer handles crop · ⌘wheel zooms · Return copies and saves"
        case .arrow: return "Drag an arrow · ⇧ snaps to 45° · A again: \(settings.arrowStyle.rawValue)"
        case .line: return "Drag a line · ⇧ snaps to 45°"
        case .pen: return "Draw · wheel sets size · ⌥wheel smoothing \(settings.smoothing)/6"
        case .highlighter: return settings.highlighterSnap ? "Snap mode: drag along text · H again for freehand" : "Freehand highlighter · wheel sets thickness"
        case .rect, .ellipse: return "Drag · ⇧ square · ⌥ from center · R/E again toggles fill"
        case .marker: return "Click to place the next number"
        case .text: return "Click for a label, or drag a box · T again: \(settings.textStyle.rawValue) · ⇧T font"
        case .redact: return "Drag over secrets · D again: \(settings.redactStyle == .pixelate ? "mosaic" : "solid")"
        case .spotlight: return "Drag a spotlight · S again: \(settings.spotlightShape.rawValue) · wheel magnifies"
        case .cut: return cutInsertArmed ? "Drag to insert a transparent band" : "Drag across a band to cut it out · hold ⌃ to insert"
        case .ocr: return "Drag a region to recognize, or click for the whole image"
        case .eyedropper: return "Click to pick a color · Esc cancels"
        }
    }

    private func drawHint() {
        Chrome.drawPill(hintText, center: CGPoint(x: bounds.midX, y: bounds.height - 26), font: Chrome.font(12, .medium))
    }

    static let shortcuts: [Chrome.Shortcut] = [
        .init(keys: "V", action: "Select / move"), .init(keys: "A", action: "Arrow (again: style)"),
        .init(keys: "L", action: "Line"), .init(keys: "F", action: "Pen"),
        .init(keys: "H", action: "Highlighter"), .init(keys: "R / E", action: "Rectangle / ellipse"),
        .init(keys: "C", action: "Numbered marker"), .init(keys: "T  ⇧T", action: "Text · font"),
        .init(keys: "D", action: "Redact"), .init(keys: "S", action: "Spotlight"),
        .init(keys: "X", action: "Cut band (⌃ inserts)"), .init(keys: "O", action: "Copy all text (OCR)"),
        .init(keys: "I", action: "Eyedropper"), .init(keys: "1–8", action: "Color"),
        .init(keys: "B  ⇧B", action: "Backdrop · shadow"), .init(keys: "G  ⇧G", action: "Canvas growth"),
        .init(keys: "W", action: "Window / overlay"), .init(keys: "⌘wheel  0", action: "Zoom · fit"),
        .init(keys: "⌥D", action: "Duplicate layer"), .init(keys: "⌘Z  ⇧⌘Z", action: "Undo · redo"),
        .init(keys: "⌘C  ⌘S", action: "Copy · save"), .init(keys: "⇧⌘S", action: "Save as…"),
        .init(keys: "Return", action: "Copy and save"), .init(keys: "P", action: "Pin on screen"),
        .init(keys: "Esc", action: "Close (keeps edits)"), .init(keys: "?", action: "Hide shortcuts"),
    ]

    private func drawGuide() {
        let size = Chrome.shortcutCardSize(Self.shortcuts, columns: 2)
        let card = toView(outputRectInSource).union(toolbar.frame)
        let top = (window?.screen?.safeAreaInsets.top ?? 0) + (overlayMode ? 16 : 40)
        // Top-right, else bottom-left; never over the capture or the hint.
        let spots = [CGPoint(x: bounds.width - size.width - 16, y: top), CGPoint(x: 16, y: bounds.height - size.height - 56)]
        guard let origin = spots.first(where: { !CGRect(origin: $0, size: size).intersects(card) && $0.y >= 0 }) else {
            guideHeader = .zero
            return
        }
        guideHeader = Chrome.drawShortcutCard(Self.shortcuts, origin: origin).header
    }

    private var guideHeader: CGRect = .zero

    // MARK: Hit testing

    private func topHit(_ p: CGPoint) -> Annotation? {
        let tol = 5 / zoom
        return displayState.annotations.reversed().first { Geometry.hitTest($0, p, tolerance: tol) }
    }

    private func handleHit(_ v: CGPoint) -> (Annotation, Handle)? {
        guard selection.count == 1, let id = selection.first, let a = displayState.annotation(id) else { return nil }
        for (h, p) in handlePoints(a) where toView(p).distance(to: v) <= 8 {
            return (a, h)
        }
        return nil
    }

    private func cropHandleHit(_ v: CGPoint) -> Handle? {
        cropHandleRects(displayState.crop).first { $0.1.insetBy(dx: -6, dy: -6).contains(v) }?.0
    }

    private func row(at p: CGPoint) -> CGRect? {
        let candidates = textRows.filter { p.y >= $0.minY - 4 && p.y <= $0.maxY + 4 && p.x >= $0.minX - 60 && p.x <= $0.maxX + 60 }
        return candidates.min { abs($0.midY - p.y) < abs($1.midY - p.y) }
    }

    func refreshTextRows() {
        let cuts = doc.state.cuts
        guard textRowsCuts != cuts else { return }
        textRowsCuts = cuts
        let img = composed
        let size = CGSize(width: CGFloat(img.width) / doc.scale, height: CGFloat(img.height) / doc.scale)
        Task { [weak self] in
            let lines = await OCR.recognize(img, fast: true)
            await MainActor.run {
                guard let self, self.textRowsCuts == cuts else { return }
                self.textRows = lines.map { CGRect(x: $0.box.minX * size.width, y: $0.box.minY * size.height,
                                                   width: $0.box.width * size.width, height: $0.box.height * size.height) }
            }
        }
    }

    private func sample(at p: CGPoint) -> RGBA? {
        let img = composed
        let x = Int(p.x * doc.scale), y = Int(p.y * doc.scale)
        guard x >= 0, y >= 0, x < img.width, y < img.height,
              let one = img.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let ctx = CaptureRenderer.makeContext(width: 1, height: 1) else { return nil }
        ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let d = ctx.data?.bindMemory(to: UInt8.self, capacity: 4) else { return nil }
        return RGBA(Double(d[0]) / 255, Double(d[1]) / 255, Double(d[2]) / 255)
    }

    // MARK: Mutations

    private func commit(_ op: EditOp) {
        doc.push(op)
        coalesce = nil
        changed()
    }

    private func commitCoalesced(_ op: EditOp, token: String) {
        if let c = coalesce, c.token == token, Date().timeIntervalSince(c.time) < 0.7 {
            doc.amend(op)
        } else {
            doc.push(op)
        }
        coalesce = (token, Date())
        changed()
    }

    private func changed() {
        selection = selection.filter { doc.state.annotation($0) != nil }
        if doc.state.cuts != (textRowsCuts ?? []) { refreshTextRows() }
        toolbar.refresh()
        viewChanged()
        controller?.documentChanged()
    }

    func undo() {
        commitText(dismissAfter: false)
        doc.undo()
        coalesce = nil
        changed()
    }

    func redo() {
        doc.redo()
        coalesce = nil
        changed()
    }

    func flash(_ message: String, seconds: Double = 2.2) {
        status = message
        statusWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.status = nil
            self?.needsDisplay = true
        }
        statusWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
        needsDisplay = true
    }

    // MARK: Tools

    func setTool(_ t: Tool) {
        commitText(dismissAfter: false)
        if t == .eyedropper, tool != .eyedropper { toolBeforeEyedropper = tool }
        tool = t
        if t != .select { selection = [] }
        if t == .highlighter { refreshTextRows() }
        toolbar.refresh()
        window?.invalidateCursorRects(for: self)
        updateCursor()
        needsDisplay = true
    }

    func toolButtonClicked(_ t: Tool) {
        if t == .ocr {
            ocrAll()
            return
        }
        if tool == t { cycleVariant(t) } else { setTool(t) }
    }

    func variantDescription(_ t: Tool) -> String {
        switch t {
        case .arrow: " (\(settings.arrowStyle.rawValue))"
        case .text: " (\(TextLayout.label(settings.textFont)), \(settings.textStyle.rawValue))"
        case .redact: settings.redactStyle == .solid ? " (solid)" : " (mosaic)"
        case .spotlight: " (\(settings.spotlightShape.rawValue))"
        case .highlighter: settings.highlighterSnap ? " (snap to text)" : " (freehand)"
        case .rect, .ellipse: settings.shapeFilled ? " (filled)" : " (outline)"
        default: ""
        }
    }

    /// Repeating a tool's key cycles its variant; selected layers of that kind follow.
    func cycleVariant(_ t: Tool) {
        func next<T: CaseIterable & Equatable>(_ v: T) -> T {
            let all = Array(T.allCases)
            return all[(all.firstIndex(of: v)! + 1) % all.count]
        }
        switch t {
        case .arrow: settings.arrowStyle = next(settings.arrowStyle)
        case .text: settings.textStyle = next(settings.textStyle)
        case .redact: settings.redactStyle = next(settings.redactStyle)
        case .spotlight: settings.spotlightShape = next(settings.spotlightShape)
        case .highlighter: settings.highlighterSnap.toggle()
        case .rect, .ellipse: settings.shapeFilled.toggle()
        default: return
        }
        applyVariantToSelection(t)
        toolbar.refresh()
        flash("\(t.title)\(variantDescription(t))", seconds: 1.4)
    }

    private func applyVariantToSelection(_ t: Tool) {
        let anns = selection.compactMap { doc.state.annotation($0) }
        var ops: [EditOp] = []
        for var a in anns {
            switch (t, a.kind) {
            case (.arrow, .arrow): a.arrowStyle = settings.arrowStyle
            case (.text, .text): a.textStyle = settings.textStyle; a.font = settings.textFont
            case (.redact, .redact): a.redactStyle = settings.redactStyle
            case (.spotlight, .spotlight): a.spotlightShape = settings.spotlightShape
            case (.rect, .rect), (.ellipse, .ellipse), (.rect, .ellipse), (.ellipse, .rect): a.filled = settings.shapeFilled
            default: continue
            }
            ops.append(.update(a))
        }
        if !ops.isEmpty { commit(.group(ops)) }
    }

    func variantMenu(for t: Tool) -> NSMenu? {
        let menu = NSMenu()
        func item(_ title: String, on: Bool, _ action: @escaping () -> Void) {
            let i = ClosureMenuItem(title: title, action: action)
            i.state = on ? .on : .off
            menu.addItem(i)
        }
        let finish = { [weak self] in
            guard let self else { return }
            self.applyVariantToSelection(t)
            if self.tool != t { self.setTool(t) }
            self.toolbar.refresh()
        }
        switch t {
        case .arrow:
            for s in ArrowStyle.allCases { item(s.rawValue.capitalized, on: settings.arrowStyle == s) { [weak self] in self?.settings.arrowStyle = s; finish() } }
        case .text:
            for f in TextFont.allCases { item(TextLayout.label(f), on: settings.textFont == f) { [weak self] in self?.settings.textFont = f; finish() } }
            menu.addItem(.separator())
            for s in TextStyle.allCases { item(s == .pill ? "On a pill" : s.rawValue.capitalized, on: settings.textStyle == s) { [weak self] in self?.settings.textStyle = s; finish() } }
        case .redact:
            item("Randomized mosaic", on: settings.redactStyle == .pixelate) { [weak self] in self?.settings.redactStyle = .pixelate; finish() }
            item("Solid", on: settings.redactStyle == .solid) { [weak self] in self?.settings.redactStyle = .solid; finish() }
        case .spotlight:
            for s in SpotlightShape.allCases { item(s.rawValue.capitalized, on: settings.spotlightShape == s) { [weak self] in self?.settings.spotlightShape = s; finish() } }
        case .highlighter:
            item("Snap to text", on: settings.highlighterSnap) { [weak self] in self?.settings.highlighterSnap = true; finish() }
            item("Freehand", on: !settings.highlighterSnap) { [weak self] in self?.settings.highlighterSnap = false; finish() }
        case .rect, .ellipse:
            item("Outline", on: !settings.shapeFilled) { [weak self] in self?.settings.shapeFilled = false; finish() }
            item("Filled", on: settings.shapeFilled) { [weak self] in self?.settings.shapeFilled = true; finish() }
            if t == .rect {
                menu.addItem(.separator())
                for r in [0.0, 6, 12, 20] {
                    item(r == 0 ? "Square corners" : "Rounded \(Int(r))", on: settings.cornerRadius == r) { [weak self] in self?.settings.cornerRadius = r; finish() }
                }
            }
        default:
            return nil
        }
        return menu
    }

    func backgroundMenu() -> NSMenu {
        let menu = NSMenu()
        let state = doc.state
        for s in backgroundCycle {
            let i = ClosureMenuItem(title: s.label) { [weak self] in self?.commit(.background(s)) }
            i.state = state.background == s ? .on : .off
            menu.addItem(i)
        }
        menu.addItem(.separator())
        let sh = ClosureMenuItem(title: "Card shadow  ⇧B") { [weak self] in self?.toggleShadow() }
        sh.state = state.shadow ? .on : .off
        menu.addItem(sh)
        menu.addItem(.separator())
        for m in CanvasMode.allCases {
            let i = ClosureMenuItem(title: "Canvas: \(m.label)") { [weak self] in self?.commit(.canvas(m)) }
            i.state = state.canvas == m ? .on : .off
            menu.addItem(i)
        }
        if controller?.canScrollCapture == true {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Scroll capture this area…") { [weak self] in self?.controller?.startScrollCapture() })
        }
        return menu
    }

    private var backgroundCycle: [Backdrop] {
        var all: [Backdrop] = [.off, .slate, .aurora, .sunset, .lagoon, .violet]
        if customBackground != nil { all.append(.custom) }
        return all + [.grayShadow, .grayFlat]
    }

    func cycleBackground() {
        let all = backgroundCycle
        let i = all.firstIndex(of: doc.state.background) ?? 0
        let next = all[(i + 1) % all.count]
        commit(.background(next))
        flash("Backdrop: \(next.label)", seconds: 1.4)
    }

    func toggleShadow() {
        commit(.shadow(!doc.state.shadow))
        flash(doc.state.shadow ? "Card shadow on" : "Card shadow off", seconds: 1.4)
    }

    func cycleCanvas(back: Bool) {
        let all = CanvasMode.allCases
        let i = all.firstIndex(of: doc.state.canvas)!
        let next = all[(i + (back ? all.count - 1 : 1)) % all.count]
        commit(.canvas(next))
        flash("Canvas: \(next.label)", seconds: 1.4)
    }

    func setColor(_ c: RGBA) {
        settings.color = c
        let ops = selection.compactMap { doc.state.annotation($0) }.filter { $0.kind != .redact }.map { a -> EditOp in
            var b = a
            b.color = c
            return .update(b)
        }
        if !ops.isEmpty { commit(.group(ops)) }
        if let ed = textEditor {
            var a = ed.annotation
            a.color = c
            textEditor?.annotation = a
            ed.view.textColor = NSColor(cgColor: c.cgColor)
            needsDisplay = true
        }
        controller?.rememberSettings(settings)
        toolbar.refresh()
    }

    func showColorPopover(from v: NSView) {
        let picker = ColorPickerView(palette: settings.palette, current: settings.color, custom: settings.customColor)
        let vc = NSViewController()
        vc.view = picker
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        picker.onPick = { [weak self, weak pop] c in
            self?.setColor(c)
            pop?.close()
        }
        picker.onEyedropper = { [weak self, weak pop] in
            pop?.close()
            self?.setTool(.eyedropper)
        }
        picker.onMore = { [weak self, weak pop] in
            pop?.close()
            self?.showColorPanel()
        }
        pop.show(relativeTo: v.bounds, of: v, preferredEdge: .maxY)
    }

    private func showColorPanel() {
        let panel = NSColorPanel.shared
        panel.level = NSWindow.Level(rawValue: (window?.level.rawValue ?? 0) + 1)
        panel.color = NSColor(cgColor: settings.customColor.cgColor) ?? .red
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        guard let c = sender.color.usingColorSpace(.sRGB) else { return }
        let rgba = RGBA(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        settings.customColor = rgba
        setColor(rgba)
    }

    // MARK: OCR

    func ocrAll() {
        commitText(dismissAfter: false)
        runOCR(region: nil)
    }

    private func runOCR(region: CGRect?) {
        let img = composed
        let crop = region ?? doc.state.crop
        let scale = doc.scale
        let px = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard !px.isNull, let part = img.cropping(to: px) else { return }
        flash("Recognizing text…", seconds: 10)
        Task { [weak self] in
            let lines = await OCR.recognize(part)
            let text = OCR.text(lines)
            await MainActor.run {
                guard let self else { return }
                if text.isEmpty {
                    self.flash("No text found")
                } else {
                    Output.copyText(text)
                    self.flash("Copied \(lines.count) line\(lines.count == 1 ? "" : "s") of text")
                    self.showOCRPanel(text)
                }
            }
        }
    }

    private func showOCRPanel(_ text: String) {
        ocrPanel?.removeFromSuperview()
        let p = OCRPanel(text: text) { [weak self] in
            self?.ocrPanel?.removeFromSuperview()
            self?.ocrPanel = nil
        }
        addSubview(p)
        ocrPanel = p
        positionOCRPanel(p)
    }

    private func positionOCRPanel(_ p: OCRPanel) {
        let card = toView(outputRectInSource)
        var x = card.maxX + 14
        if x + p.frame.width > bounds.width - 8 { x = max(8, card.minX - p.frame.width - 14) }
        if x < 8 { x = bounds.width - p.frame.width - 8 }
        let y = min(max(60, card.minY), bounds.height - p.frame.height - 60)
        p.setFrameOrigin(CGPoint(x: x, y: y))
    }

    // MARK: Cursor

    override func cursorUpdate(with event: NSEvent) { updateCursor() }

    private func updateCursor() {
        if spaceDown { NSCursor.openHand.set(); return }
        if hideHandles { NSCursor.hide(); return }
        switch tool {
        case .select:
            let v = pointer
            if handleHit(v) != nil || (selection.isEmpty && cropHandleHit(v) != nil) { NSCursor.crosshair.set() }
            else if topHit(toSource(v)) != nil { NSCursor.openHand.set() }
            else { NSCursor.arrow.set() }
        case .text: NSCursor.iBeam.set()
        case .highlighter where settings.highlighterSnap && row(at: toSource(pointer)) != nil: NSCursor.iBeam.set()
        default: NSCursor.crosshair.set()
        }
    }

    // MARK: Mouse

    private func loc(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseMoved(with e: NSEvent) {
        pointer = loc(e)
        updateCursor()
        if tool == .eyedropper || tool == .highlighter { needsDisplay = true }
    }

    override func mouseDown(with e: NSEvent) {
        let v = loc(e)
        pointer = v
        if !Chrome.guideHidden, guideHeader.contains(v) {
            Chrome.guideHidden = true
            needsDisplay = true
            return
        }
        if textEditor != nil {
            commitText(dismissAfter: false)
            if tool == .text { setTool(.select) }
            return
        }
        window?.makeFirstResponder(self)
        let p = toSource(v)
        if spaceDown {
            drag = .pan(startView: v, startPan: pan)
            NSCursor.closedHand.set()
            return
        }
        if e.clickCount == 2, let hit = topHit(p), hit.kind == .text {
            beginTextEdit(hit, isNew: false)
            return
        }
        // Handles of the selected layer win over every tool.
        if let (a, h) = handleHit(v) {
            drag = .handle(h, original: a, frame: Geometry.frame(a))
            if a.kind == .arrow || a.kind == .line { hideHandles = true; NSCursor.hide() }
            return
        }
        if tool != .select, let hit = topHit(p), selection.contains(hit.id) {
            startMove(p)
            return
        }
        switch tool {
        case .select:
            if let hit = topHit(p) {
                if e.modifierFlags.contains(.shift) {
                    if selection.contains(hit.id) { selection.remove(hit.id) } else { selection.insert(hit.id) }
                } else if !selection.contains(hit.id) {
                    selection = [hit.id]
                }
                startMove(p)
            } else if selection.isEmpty, let h = cropHandleHit(v) {
                drag = .crop(h, original: doc.state.crop)
            } else {
                selection = []
                drag = .marquee(start: p)
            }
            toolbar.refresh()
        case .marker:
            var a = settings.make(.marker, id: doc.allocateId())
            a.points = [p]
            a.number = doc.state.nextMarkerNumber
            commit(.add(a))
        case .text:
            if let hit = topHit(p), hit.kind == .text {
                beginTextEdit(hit, isNew: false)
            } else {
                drag = .textBox(start: p)
            }
        case .cut:
            drag = .cut(start: p, insert: cutInsertArmed || e.modifierFlags.contains(.control))
        case .ocr:
            drag = .ocr(start: p)
        case .eyedropper:
            if let c = sample(at: p) {
                settings.customColor = c
                setColor(c)
                flash("Picked \(c.hex)")
            }
            setTool(toolBeforeEyedropper == .eyedropper ? .select : toolBeforeEyedropper)
        default:
            guard let kind = tool.annotationKind else { return }
            var a = settings.make(kind, id: doc.allocateId())
            switch kind {
            case .arrow, .line:
                a.points = [p, p]
            case .pen:
                a.points = [p]
            case .highlighter:
                if settings.highlighterSnap, let r = row(at: p) {
                    a.snapped = true
                    a.width = max(6, r.height * 1.15)
                    let y = r.midY
                    a.points = [CGPoint(x: p.x, y: y), CGPoint(x: p.x, y: y)]
                } else {
                    a.points = [p]
                }
            default:
                a.rect = CGRect(origin: p, size: .zero)
            }
            liveNew = a
            drag = .create(start: p, centered: e.modifierFlags.contains(.option))
        }
        needsDisplay = true
    }

    private func startMove(_ p: CGPoint) {
        let originals = selection.compactMap { doc.state.annotation($0) }
        drag = .move(start: p, originals: originals, moved: false)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with e: NSEvent) {
        let v = loc(e)
        pointer = v
        var p = toSource(v)
        let shift = e.modifierFlags.contains(.shift)
        let alt = e.modifierFlags.contains(.option)
        switch drag {
        case .none:
            return
        case .pan(let sv, let sp):
            pan = CGPoint(x: sp.x + v.x - sv.x, y: sp.y + v.y - sv.y)
            viewChanged()
            return
        case .create(let start, let centered):
            guard var a = liveNew else { return }
            switch a.kind {
            case .arrow, .line:
                if shift { p = Geometry.snap45(p, origin: start) }
                a.points[1] = p
            case .pen:
                if let last = a.points.last, last.distance(to: p) * zoom >= 1 { a.points.append(p) }
            case .highlighter:
                if a.snapped {
                    a.points[1] = CGPoint(x: p.x, y: a.points[0].y)
                } else if let last = a.points.last, last.distance(to: p) * zoom >= 1 {
                    a.points.append(shift ? CGPoint(x: p.x, y: a.points[0].y) : p)
                }
            default:
                var q = p
                if shift {
                    let d = max(abs(p.x - start.x), abs(p.y - start.y))
                    q = CGPoint(x: start.x + (p.x >= start.x ? d : -d), y: start.y + (p.y >= start.y ? d : -d))
                }
                if centered || alt {
                    let dx = q.x - start.x, dy = q.y - start.y
                    a.rect = CGRect(CGPoint(x: start.x - dx, y: start.y - dy), q)
                } else {
                    a.rect = CGRect(start, q)
                }
            }
            liveNew = a
        case .textBox(let start):
            marquee = CGRect(start, p)
        case .move(let start, let originals, _):
            let d = p - start
            for a in originals { liveOverrides[a.id] = Geometry.translated(a, by: d) }
            drag = .move(start: start, originals: originals, moved: d.length * zoom > 1)
        case .handle(let h, let original, let frame):
            var a = original
            switch h {
            case .start, .end:
                let other = h == .start ? original.points[1] : original.points[0]
                if shift { p = Geometry.snap45(p, origin: other) }
                // Keep a curved arrow's bend proportional while endpoints move.
                if let bend = Geometry.bendPoint(original) {
                    let oldMid = original.points[0].mid(original.points[1])
                    a.points[h == .start ? 0 : 1] = p
                    a.bend = a.points[0].mid(a.points[1]) + (bend - oldMid)
                } else {
                    a.points[h == .start ? 0 : 1] = p
                }
            case .bend:
                if shift {
                    // Keep the bend on the perpendicular through the midpoint.
                    let m = original.points[0].mid(original.points[1])
                    let d = original.points[1] - original.points[0]
                    let len = max(0.001, d.length)
                    let n = CGPoint(x: -d.y / len, y: d.x / len)
                    let t = (p.x - m.x) * n.x + (p.y - m.y) * n.y
                    p = m + n * t
                }
                a.bend = p
            default:
                let keep = shift && [.rect, .ellipse, .redact, .spotlight].contains(original.kind)
                let nf = h.resize(frame, to: p, keepAspect: keep || (original.kind == .marker))
                if original.kind == .text {
                    a = original
                    if h == .left || h == .right {
                        a.points = [CGPoint(x: nf.minX, y: frame.minY)]
                        a.wrapWidth = max(30, nf.width)
                    } else {
                        // Corner handles scale the type.
                        let k = max(0.2, nf.width / max(1, frame.width))
                        a.width = min(400, max(6, original.width * k))
                        if let w = original.wrapWidth { a.wrapWidth = w * k }
                        a.points = [CGPoint(x: nf.minX, y: nf.minY)]
                    }
                } else {
                    a = Geometry.refit(original, from: frame, to: nf)
                }
            }
            liveOverrides[a.id] = a
        case .crop(let h, let original):
            let full = CGRect(origin: .zero, size: CGSize(width: CGFloat(composed.width) / doc.scale, height: CGFloat(composed.height) / doc.scale))
            var r = h.resize(original, to: p).intersection(full)
            if r.isNull || r.width < 8 || r.height < 8 { r = liveCrop ?? original }
            liveCrop = r.integral
        case .marquee(let start):
            marquee = CGRect(start, p)
        case .cut(let start, let insert):
            let d = p - start
            let crop = doc.state.crop
            if abs(d.y) >= abs(d.x) {
                cutPreview = CutBand(axis: .rows, start: max(crop.minY, min(start.y, p.y)), end: min(crop.maxY, max(start.y, p.y)), insert: insert)
            } else {
                cutPreview = CutBand(axis: .columns, start: max(crop.minX, min(start.x, p.x)), end: min(crop.maxX, max(start.x, p.x)), insert: insert)
            }
        case .ocr(let start):
            ocrRect = CGRect(start, p)
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        let p = toSource(loc(e))
        let d = drag
        drag = .none
        if hideHandles {
            hideHandles = false
            NSCursor.unhide()
        }
        switch d {
        case .none, .pan:
            break
        case .create:
            guard let a = liveNew else { break }
            liveNew = nil
            if isMeaningful(a) {
                commit(.add(a))
                // Creation tools return to Select after one placement.
                setTool(.select)
            }
        case .textBox(let start):
            let box = marquee ?? CGRect(origin: start, size: .zero)
            marquee = nil
            var a = settings.make(.text, id: doc.allocateId())
            a.points = [box.width * zoom > 24 ? CGPoint(x: box.minX, y: box.minY) : start]
            if box.width * zoom > 24 { a.wrapWidth = box.width }
            beginTextEdit(a, isNew: true)
        case .move(_, let originals, let moved):
            let ops = originals.compactMap { liveOverrides[$0.id] }.map { EditOp.update($0) }
            liveOverrides = [:]
            if moved, !ops.isEmpty { commit(ops.count == 1 ? ops[0] : .group(ops)) }
        case .handle(_, let original, _):
            if let a = liveOverrides[original.id], a != original { commit(.update(a)) }
            liveOverrides = [:]
        case .crop(_, let original):
            if let r = liveCrop, r != original { commit(.crop(r)) }
            liveCrop = nil
        case .marquee:
            if let m = marquee, m.width * zoom > 2 || m.height * zoom > 2 {
                selection = Set(doc.state.annotations.filter { Geometry.frame($0).intersects(m) }.map(\.id))
            }
            marquee = nil
            toolbar.refresh()
        case .cut:
            if let band = cutPreview, band.length * zoom >= 2 {
                selection = []
                commit(.cut(band))
                flash(band.insert ? "Inserted a \(Int(band.length * doc.scale)) px band" : "Cut \(Int(band.length * doc.scale)) px")
            }
            cutPreview = nil
        case .ocr(let start):
            let r = CGRect(start, p)
            ocrRect = nil
            runOCR(region: r.width * zoom > 6 && r.height * zoom > 6 ? r : nil)
            setTool(.select)
        }
        updateCursor()
        needsDisplay = true
    }

    private func isMeaningful(_ a: Annotation) -> Bool {
        let f = Geometry.frame(a)
        switch a.kind {
        case .arrow, .line: return a.points[0].distance(to: a.points[1]) * zoom >= 6
        case .pen: return !a.points.isEmpty
        case .highlighter: return a.snapped ? abs(a.points[1].x - a.points[0].x) * zoom >= 4 : !a.points.isEmpty
        default: return f.width * zoom >= 4 && f.height * zoom >= 4
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelGesture()
        commitText(dismissAfter: false)
        setTool(.select)
    }

    override func otherMouseDown(with e: NSEvent) {
        drag = .pan(startView: loc(e), startPan: pan)
        NSCursor.closedHand.set()
    }

    override func otherMouseDragged(with e: NSEvent) { mouseDragged(with: e) }
    override func otherMouseUp(with e: NSEvent) {
        drag = .none
        updateCursor()
    }

    private func cancelGesture() {
        drag = .none
        liveNew = nil
        liveOverrides = [:]
        liveCrop = nil
        cutPreview = nil
        marquee = nil
        ocrRect = nil
        if hideHandles {
            hideHandles = false
            NSCursor.unhide()
        }
        needsDisplay = true
    }

    // MARK: Wheel and pinch

    override func magnify(with e: NSEvent) {
        setZoom(zoom * (1 + e.magnification), about: loc(e))
    }

    override func scrollWheel(with e: NSEvent) {
        let v = loc(e)
        let p = toSource(v)
        let precise = e.hasPreciseScrollingDeltas
        let dy = precise ? e.scrollingDeltaY / 12 : e.scrollingDeltaY
        let flags = e.modifierFlags
        if flags.contains(.command) || flags.contains(.control) {
            setZoom(zoom * pow(1.12, dy), about: v)
            return
        }
        if flags.contains(.shift), !precise {
            pan.x += e.scrollingDeltaY * 12
            viewChanged()
            return
        }
        guard abs(dy) > 0.01 else {
            if precise { pan.x += e.scrollingDeltaX; viewChanged() }
            return
        }
        let step: CGFloat = dy > 0 ? 1 : -1
        if flags.contains(.option) {
            altWheel(step, at: p)
            return
        }
        if !selection.isEmpty, !precise || abs(e.scrollingDeltaY) > abs(e.scrollingDeltaX) {
            let k = pow(1.06, step)
            let ops = selection.compactMap { doc.state.annotation($0) }.map { EditOp.update(Geometry.scaled($0, by: k)) }
            commitCoalesced(.group(ops), token: "scale-\(selection.sorted())")
            return
        }
        if let spot = displayState.annotations.last(where: { $0.kind == .spotlight && $0.rect.standardized.contains(p) }),
           tool == .select || tool == .spotlight {
            var s = spot
            s.magnification = min(4, max(1, s.magnification + 0.15 * step))
            commitCoalesced(.update(s), token: "mag-\(s.id)")
            flash(String(format: "Magnification %.2f×", s.magnification), seconds: 1)
            return
        }
        if tool.creates, let k = tool.annotationKind, k != .redact, k != .spotlight {
            let r = ToolSettings.sizeRange(k)
            let cur = settings.size(k)
            let delta = k == .text || k == .marker || k == .highlighter ? 2.0 : 1.0
            settings.sizes[k] = min(r.upperBound, max(r.lowerBound, cur + delta * Double(step)))
            flash("Size \(Int(settings.size(k))) · scroll wheel", seconds: 1)
            controller?.rememberSettings(settings)
            return
        }
        // Just viewing: scroll a zoomed capture like a document.
        pan.y += precise ? e.scrollingDeltaY : e.scrollingDeltaY * 12
        pan.x += precise ? e.scrollingDeltaX : e.scrollingDeltaX * 12
        viewChanged()
    }

    private func altWheel(_ step: CGFloat, at p: CGPoint) {
        if let id = selection.first, selection.count == 1, var a = doc.state.annotation(id) {
            switch a.kind {
            case .pen:
                a.smoothing = max(0, min(6, a.smoothing + Int(step)))
                flash("Smoothing \(a.smoothing)/6", seconds: 1)
            case .rect:
                a.cornerRadius = max(0, min(80, a.cornerRadius + 2 * step))
                flash("Corner radius \(Int(a.cornerRadius))", seconds: 1)
            case .spotlight:
                a.width = max(0, min(20, a.width + step))
                flash("Spotlight border \(Int(a.width))", seconds: 1)
            default:
                a.width = max(1, min(120, a.width + step))
            }
            commitCoalesced(.update(a), token: "alt-\(id)")
            return
        }
        switch tool {
        case .pen:
            settings.smoothing = max(0, min(6, settings.smoothing + Int(step)))
            flash("Next pen smoothing \(settings.smoothing)/6", seconds: 1)
        case .rect:
            settings.cornerRadius = max(0, min(80, settings.cornerRadius + 2 * step))
            flash("Corner radius \(Int(settings.cornerRadius))", seconds: 1)
        case .spotlight:
            settings.spotlightBorder = max(0, min(20, settings.spotlightBorder + step))
            flash("Spotlight border \(Int(settings.spotlightBorder))", seconds: 1)
        case .highlighter:
            settings.sizes[.highlighter] = max(4, min(80, settings.size(.highlighter) + 2 * step))
            flash("Highlighter \(Int(settings.size(.highlighter)))", seconds: 1)
        default: break
        }
    }

    // MARK: Keyboard

    override func flagsChanged(with e: NSEvent) {
        let armed = tool == .cut && e.modifierFlags.contains(.control)
        if armed != cutInsertArmed {
            cutInsertArmed = armed
            toolbar.refresh()
            needsDisplay = true
        }
    }

    override func keyUp(with e: NSEvent) {
        if e.keyCode == 49 {
            spaceDown = false
            updateCursor()
        }
    }

    override func keyDown(with e: NSEvent) {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = f.contains(.command)
        let shift = f.contains(.shift)
        let alt = f.contains(.option)
        let ctrl = f.contains(.control)
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let c = controller

        switch e.keyCode {
        case 53: // Esc
            if case .none = drag {
                if tool == .eyedropper { setTool(toolBeforeEyedropper); return }
                c?.perform(.dismiss)
            } else {
                cancelGesture()
            }
            return
        case 36, 76: // Return
            if selection.count == 1, let id = selection.first, let a = doc.state.annotation(id), a.kind == .text {
                beginTextEdit(a, isNew: false)
            } else {
                c?.perform(.copyAndSave)
            }
            return
        case 51, 117: // Delete
            if !selection.isEmpty {
                commit(.remove(Array(selection)))
                selection = []
            }
            return
        case 49: // Space: hold to pan
            spaceDown = true
            updateCursor()
            return
        case 123, 124, 125, 126:
            let d: CGFloat = shift ? 10 : 1
            let v: CGPoint = switch e.keyCode {
            case 123: CGPoint(x: -d, y: 0)
            case 124: CGPoint(x: d, y: 0)
            case 125: CGPoint(x: 0, y: d)
            default: CGPoint(x: 0, y: -d)
            }
            if selection.isEmpty {
                pan = pan - v * 4
                viewChanged()
            } else {
                let ops = selection.compactMap { doc.state.annotation($0) }.map { EditOp.update(Geometry.translated($0, by: v)) }
                if e.isARepeat { commitCoalesced(.group(ops), token: "nudge") } else { coalesce = nil; commitCoalesced(.group(ops), token: "nudge") }
            }
            return
        default:
            break
        }

        if cmd {
            switch ch {
            case "z": shift ? redo() : undo()
            case "y": redo()
            case "c": c?.perform(.copy)
            case "s": c?.perform(shift ? .saveAs : .save)
            case "p": c?.perform(.pin)
            case "w": c?.perform(.dismiss)
            case "a":
                selection = Set(doc.state.annotations.map(\.id))
                setTool(.select)
                selection = Set(doc.state.annotations.map(\.id))
                needsDisplay = true
            case "=", "+": setZoom(zoom * 1.25, about: CGPoint(x: bounds.midX, y: bounds.midY))
            case "-": setZoom(zoom / 1.25, about: CGPoint(x: bounds.midX, y: bounds.midY))
            case "0": fit()
            default: break
            }
            return
        }
        if ctrl, ch == "x" {
            setTool(.cut)
            cutInsertArmed = true
            toolbar.refresh()
            return
        }
        if alt, e.keyCode == 2 { // ⌥D (character is ∂)
            duplicateSelection()
            return
        }
        if let n = Int(ch), (1...8).contains(n), n <= settings.palette.count {
            setColor(settings.palette[n - 1])
            return
        }
        switch ch {
        case "v": setTool(.select)
        case "a": keyTool(.arrow)
        case "l": keyTool(.line)
        case "f": keyTool(.pen)
        case "h": keyTool(.highlighter)
        case "r": keyTool(.rect)
        case "e": keyTool(.ellipse)
        case "c": keyTool(.marker)
        case "t":
            if shift {
                let all = TextFont.allCases
                settings.textFont = all[(all.firstIndex(of: settings.textFont)! + 1) % all.count]
                applyVariantToSelection(.text)
                flash("Font: \(TextLayout.label(settings.textFont))", seconds: 1.4)
                toolbar.refresh()
            } else {
                keyTool(.text)
            }
        case "d": keyTool(.redact)
        case "s": keyTool(.spotlight)
        case "x": keyTool(.cut)
        case "o": ocrAll()
        case "i": setTool(.eyedropper)
        case "b": shift ? toggleShadow() : cycleBackground()
        case "g": cycleCanvas(back: shift)
        case "w": c?.togglePresentation()
        case "p": c?.perform(.pin)
        case "=", "+": setZoom(zoom * 1.25, about: CGPoint(x: bounds.midX, y: bounds.midY))
        case "-": setZoom(zoom / 1.25, about: CGPoint(x: bounds.midX, y: bounds.midY))
        case "0": fit()
        case "?", "/":
            Chrome.guideHidden.toggle()
            needsDisplay = true
        default:
            break
        }
    }

    private func keyTool(_ t: Tool) {
        if tool == t { cycleVariant(t) } else { setTool(t) }
    }

    private func duplicateSelection() {
        var ops: [EditOp] = []
        var newIds: Set<Int> = []
        var next = doc.allocateId()
        let crop = doc.state.crop
        for a in selection.compactMap({ doc.state.annotation($0) }) {
            let f = Geometry.frame(a)
            var d = CGPoint(x: -14, y: 14)
            if f.minX - 14 < crop.minX { d.x = 14 }
            if f.maxY + 14 > crop.maxY { d.y = -14 }
            var b = Geometry.translated(a, by: d)
            b.id = next
            if b.kind == .marker { b.number = doc.state.nextMarkerNumber + newIds.count }
            next += 1
            newIds.insert(b.id)
            ops.append(.add(b))
        }
        guard !ops.isEmpty else { return }
        commit(.group(ops))
        selection = newIds
        needsDisplay = true
    }

    // MARK: Text editing

    private func beginTextEdit(_ a: Annotation, isNew: Bool) {
        commitText(dismissAfter: false)
        selection = []
        let tv = NSTextView(frame: .zero)
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.delegate = self
        tv.insertionPointColor = NSColor(cgColor: a.color.cgColor) ?? .white
        tv.focusRingType = .none
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.string = a.text
        textEditor = (tv, a, isNew)
        if isNew { liveNew = a }
        applyTextAttributes(tv, a)
        addSubview(tv)
        layoutTextView(tv, for: a)
        window?.makeFirstResponder(tv)
        if !isNew { tv.selectAll(nil) }
        needsDisplay = true
    }

    private func scaledAttributes(_ a: Annotation) -> [NSAttributedString.Key: Any] {
        var b = a
        b.width = a.width * zoom
        let s = TextLayout.attributed(b, text: "x")
        var attrs = s.attributes(at: 0, effectiveRange: nil)
        if a.textStyle == .outline { attrs[.strokeWidth] = -3.0 }
        return attrs
    }

    private func applyTextAttributes(_ tv: NSTextView, _ a: Annotation) {
        let attrs = scaledAttributes(a)
        tv.typingAttributes = attrs
        tv.textStorage?.setAttributes(attrs, range: NSRange(location: 0, length: tv.string.utf16.count))
    }

    private func layoutTextView(_ tv: NSTextView, for a: Annotation) {
        var b = a
        b.text = tv.string
        let box = TextLayout.box(b)
        let pad = TextLayout.padding(b)
        let inner = box.insetBy(dx: pad.width, dy: pad.height)
        var r = toView(inner)
        r.size.width = max(r.width + 4 * zoom, 20)
        tv.frame = r
        if let tc = tv.textContainer {
            if let w = a.wrapWidth {
                tc.containerSize = CGSize(width: (w - 2 * pad.width) * zoom, height: .greatestFiniteMagnitude)
                tc.widthTracksTextView = false
            } else {
                tc.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
                tc.widthTracksTextView = false
            }
        }
        if zoom != 1 || true { applyTextAttributesIfNeeded(tv, a) }
    }

    private var lastAppliedTextZoom: CGFloat = 0
    private func applyTextAttributesIfNeeded(_ tv: NSTextView, _ a: Annotation) {
        if lastAppliedTextZoom != zoom {
            lastAppliedTextZoom = zoom
            applyTextAttributes(tv, a)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let ed = textEditor else { return }
        var a = ed.annotation
        a.text = ed.view.string
        textEditor?.annotation = a
        liveOverrides[a.id] = ed.isNew ? nil : a
        if ed.isNew { liveNew = a }
        layoutTextView(ed.view, for: a)
        needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                commitText(dismissAfter: false)
                setTool(.select)
            }
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            commitText(dismissAfter: true)
            return true
        }
        return false
    }

    func commitText(dismissAfter: Bool) {
        guard let ed = textEditor else {
            if dismissAfter { controller?.perform(.dismiss) }
            return
        }
        textEditor = nil
        lastAppliedTextZoom = 0
        var a = ed.annotation
        a.text = ed.view.string.trimmingCharacters(in: .newlines)
        ed.view.removeFromSuperview()
        liveNew = nil
        liveOverrides[a.id] = nil
        window?.makeFirstResponder(self)
        let trimmed = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ed.isNew {
            if !trimmed.isEmpty { commit(.add(a)) }
        } else if trimmed.isEmpty {
            commit(.remove([a.id]))
        } else if doc.state.annotation(a.id) != a {
            commit(.update(a))
        }
        needsDisplay = true
        if dismissAfter { controller?.perform(.dismiss) }
    }
}

/// HUD panel listing recognized text beside the capture.
final class OCRPanel: HUDBar {
    init(text: String, onClose: @escaping () -> Void) {
        super.init(frame: CGRect(x: 0, y: 0, width: 300, height: 260))
        let title = NSTextField(labelWithString: "Recognized text · copied")
        title.font = Chrome.font(11, .semibold)
        title.textColor = Chrome.dimText
        title.frame = CGRect(x: 12, y: 8, width: 230, height: 18)
        addSubview(title)
        let close = HUDButton(symbol: "xmark", tip: "Close", size: CGSize(width: 26, height: 26), action: onClose)
        close.frame.origin = CGPoint(x: 270, y: 4)
        addSubview(close)
        let scroll = NSScrollView(frame: CGRect(x: 10, y: 32, width: 280, height: 218))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.string = text
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textColor = Chrome.text
        tv.font = Chrome.font(12)
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
