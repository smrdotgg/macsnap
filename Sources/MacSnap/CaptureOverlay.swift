import AppKit
import MacSnapCore

enum CaptureMode: String, CaseIterable {
    case smart, region, window, fullscreen, scroll

    var label: String {
        switch self {
        case .smart: "Smart"
        case .region: "Area"
        case .window: "Window"
        case .fullscreen: "Screen"
        case .scroll: "Scroll"
        }
    }
}

struct CaptureSelection {
    /// Screen-local, top-left origin points.
    var rect: CGRect
    var app: String?
}

struct RecentCard {
    var entry: RecentStore.Entry
    var image: NSImage
}

@MainActor
final class CaptureOverlay: NSObject {
    enum Outcome {
        case cancelled
        case selected(CaptureSelection, annotate: Bool)
        case scroll(CGRect, annotate: Bool)
        case recent(RecentStore.Entry)
    }

    let snap: ScreenSnapshot
    let panel: KeyPanel
    let view: CaptureOverlayView
    private var onFinish: ((Outcome) -> Void)?

    init(snap: ScreenSnapshot, mode: CaptureMode, annotate: Bool, recents: [RecentCard], onFinish: @escaping (Outcome) -> Void) {
        self.snap = snap
        self.onFinish = onFinish
        panel = KeyPanel(frame: snap.screen.frame, level: .screenSaver)
        panel.isOpaque = true
        panel.backgroundColor = .black
        view = CaptureOverlayView(frame: CGRect(origin: .zero, size: snap.screen.frame.size), snap: snap, mode: mode, annotate: annotate, recents: recents)
        super.init()
        panel.contentView = view
        view.finish = { [weak self] outcome in self?.finish(outcome) }
    }

    func show() {
        panel.setFrame(snap.screen.frame, display: false)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        view.syncPointer()
        NSCursor.crosshair.set()
    }

    func finish(_ outcome: Outcome) {
        guard let cb = onFinish else { return }
        onFinish = nil
        panel.orderOut(nil)
        NSCursor.arrow.set()
        // Defer: we may be inside the overlay view's own event handling, and
        // the callback releases the panel.
        DispatchQueue.main.async { cb(outcome) }
    }

    func cancel() { finish(.cancelled) }
}

final class CaptureOverlayView: NSView {
    enum Aspect: CaseIterable {
        case free, square, portrait, wide
        var label: String {
            switch self {
            case .free: "Free"
            case .square: "1:1"
            case .portrait: "3:4"
            case .wide: "16:9"
            }
        }
        var ratio: CGFloat? {
            switch self {
            case .free: nil
            case .square: 1
            case .portrait: 3.0 / 4.0
            case .wide: 16.0 / 9.0
            }
        }
    }

    let snap: ScreenSnapshot
    var mode: CaptureMode
    var annotate: Bool
    var recents: [RecentCard]
    var finish: ((CaptureOverlay.Outcome) -> Void)?

    private var pointer: CGPoint = .zero
    private var dragStart: CGPoint?
    private var dragging = false
    private var aspect: Aspect = .free
    private var hovered: WindowInfo?
    private var pending: CGRect?
    private var shelfOpen = false
    private var shelfFoldWork: DispatchWorkItem?
    private var tabRects: [(CaptureMode, CGRect)] = []
    private var annotateRect: CGRect = .zero
    private var tabStripBottom: CGFloat = 0
    private var guideHeaderRect: CGRect = .zero
    private var cardRects: [(Int, CGRect)] = []

    init(frame: CGRect, snap: ScreenSnapshot, mode: CaptureMode, annotate: Bool, recents: [RecentCard]) {
        self.snap = snap
        self.mode = mode
        self.annotate = annotate
        self.recents = recents
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    /// ⌘A arrives through the Edit menu's key equivalent.
    @objc override func selectAll(_ sender: Any?) {
        finish?(.selected(CaptureSelection(rect: bounds, app: nil), annotate: annotate))
    }

    func syncPointer() {
        guard let w = window else { return }
        let p = w.mouseLocationOutsideOfEventStream
        pointer = CGPoint(x: p.x, y: bounds.height - p.y)
        updateHover()
        needsDisplay = true
    }

    // MARK: Geometry

    private var selectionRect: CGRect? {
        guard let s = dragStart, dragging else { return nil }
        return constrained(from: s, to: pointer)
    }

    private func constrained(from a: CGPoint, to b: CGPoint) -> CGRect {
        guard let ratio = aspect.ratio else { return CGRect(a, b).intersection(bounds) }
        let dx = b.x - a.x, dy = b.y - a.y
        var w = abs(dx), h = abs(dy)
        if w / max(h, 1) > ratio { h = w / ratio } else { w = h * ratio }
        let r = CGRect(x: dx < 0 ? a.x - w : a.x, y: dy < 0 ? a.y - h : a.y, width: w, height: h)
        return r.intersection(bounds)
    }

    /// The area that would be captured if the user clicked now.
    private var litRect: CGRect? {
        if let s = selectionRect { return s }
        if let p = pending { return p }
        switch mode {
        case .region, .scroll: return nil
        case .window: return hovered?.frame
        case .smart: return hovered?.frame ?? bounds
        case .fullscreen: return bounds
        }
    }

    private func updateHover() {
        guard mode == .smart || mode == .window, !dragging, !shelfContains(pointer) else {
            hovered = nil
            return
        }
        hovered = snap.windows.first { $0.frame.contains(pointer) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        CaptureRenderer.drawImage(snap.image, in: bounds, ctx: ctx)
        let lit = litRect
        // Dim everything except what would be captured.
        if lit != bounds {
            ctx.saveGState()
            ctx.addRect(bounds)
            if let lit { ctx.addRect(lit) }
            ctx.setFillColor(Chrome.scrim.cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }
        if let lit, lit != bounds {
            let accent = Chrome.accent
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(selectionRect != nil || pending != nil ? 1.5 : 2.5)
            ctx.stroke(lit.insetBy(dx: -0.75, dy: -0.75))
        }
        drawCrosshair(ctx)
        drawReadout()
        drawTabs()
        drawHint()
        if !Chrome.guideHidden { drawGuide() } else { guideHeaderRect = .zero }
        drawShelf(ctx)
    }

    private func drawCrosshair(_ ctx: CGContext) {
        guard !shelfContains(pointer) else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.42).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        let x = floor(pointer.x) + 0.5, y = floor(pointer.y) + 0.5
        ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: bounds.height))
        ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: bounds.width, y: y))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func px(_ v: CGFloat) -> Int { Int((v * snap.scale).rounded()) }

    private func drawReadout() {
        guard !shelfContains(pointer) else { return }
        var text: String
        if let s = selectionRect {
            text = "\(px(s.width)) × \(px(s.height))"
            if aspect != .free { text += "  \(aspect.label)" }
        } else if let h = hovered {
            text = "\(px(h.frame.width)) × \(px(h.frame.height))  \(h.app)"
        } else {
            text = "\(px(pointer.x)), \(px(pointer.y))"
            if aspect != .free { text += "  \(aspect.label)" }
        }
        let size = Chrome.pillSize(text, font: Chrome.mono(11))
        var c = CGPoint(x: pointer.x + 18 + size.width / 2, y: pointer.y + 22 + size.height / 2)
        if c.x + size.width / 2 > bounds.width - 6 { c.x = pointer.x - 18 - size.width / 2 }
        if c.y + size.height / 2 > bounds.height - 6 { c.y = pointer.y - 22 - size.height / 2 }
        Chrome.drawPill(text, center: c, font: Chrome.mono(11), padding: CGSize(width: 8, height: 4))
    }

    private func drawTabs() {
        let modes: [CaptureMode] = [.smart, .region, .window, .fullscreen, .scroll]
        let font = Chrome.font(12, .semibold)
        let sizes = modes.map { Chrome.pillSize($0.label, font: font, padding: CGSize(width: 12, height: 5)) }
        let annotateText = "Annotate \(annotate ? "on" : "off")"
        let aSize = Chrome.pillSize(annotateText, font: font, padding: CGSize(width: 12, height: 5))
        let total = sizes.reduce(0) { $0 + $1.width } + CGFloat(modes.count - 1) * 4 + 14 + aSize.width + 12
        let h = sizes[0].height + 8
        let top: CGFloat = (window?.screen?.safeAreaInsets.top ?? 0) + 34
        let strip = CGRect(x: bounds.midX - total / 2, y: top, width: total, height: h)
        tabStripBottom = strip.maxY
        let path = NSBezierPath(roundedRect: strip, xRadius: h / 2, yRadius: h / 2)
        Chrome.surface.setFill(); path.fill()
        Chrome.border.setStroke(); path.stroke()
        var x = strip.minX + 4
        tabRects = []
        for (m, s) in zip(modes, sizes) {
            let r = CGRect(x: x, y: strip.minY + 4, width: s.width, height: s.height)
            let active = m == mode
            if active {
                let p = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
                Chrome.accent.setFill(); p.fill()
            }
            let str = NSAttributedString(string: m.label, attributes: Chrome.attrs(font, active ? .white : Chrome.dimText))
            str.draw(at: CGPoint(x: r.minX + 12, y: r.minY + 5))
            tabRects.append((m, r))
            x += s.width + 4
        }
        x += 10
        annotateRect = CGRect(x: x, y: strip.minY + 4, width: aSize.width, height: aSize.height)
        let ap = NSBezierPath(roundedRect: annotateRect, xRadius: annotateRect.height / 2, yRadius: annotateRect.height / 2)
        (annotate ? Chrome.accent.withAlphaComponent(0.35) : Chrome.surfaceRaised).setFill()
        ap.fill()
        NSAttributedString(string: annotateText, attributes: Chrome.attrs(font, annotate ? .white : Chrome.dimText))
            .draw(at: CGPoint(x: annotateRect.minX + 12, y: annotateRect.minY + 5))
    }

    private func drawHint() {
        let text: String
        if pending != nil {
            text = "Return or click inside to capture · drag to draw a new area"
        } else {
            switch mode {
            case .smart: text = "Drag for an area · click a window · click open space for the full screen"
            case .region: text = "Drag to select an area · Tab cycles the shape"
            case .window: text = "Click a window · ⌘ arrows move between windows · Return captures"
            case .fullscreen: text = "Click to capture the full screen"
            case .scroll: text = "Drag the scrolling region, then scroll it yourself or let MacSnap scroll"
            }
        }
        Chrome.drawPill(text, center: CGPoint(x: bounds.midX, y: bounds.height - 40), font: Chrome.font(12, .medium))
    }

    static let shortcuts: [Chrome.Shortcut] = [
        .init(keys: "Click", action: "Window, or full screen"),
        .init(keys: "Drag", action: "Area, with its pixel size"),
        .init(keys: "Tab", action: "Shape: free, 1:1, 3:4, 16:9"),
        .init(keys: "S", action: "Scrolling area"),
        .init(keys: "E / A", action: "Annotate after capture"),
        .init(keys: "R", action: "Restore last area"),
        .init(keys: "⌘A", action: "Full screen"),
        .init(keys: "Return", action: "Capture highlighted"),
        .init(keys: "⌘ arrows", action: "Move between windows"),
        .init(keys: "Esc", action: "Dismiss"),
    ]

    private func drawGuide() {
        let size = Chrome.shortcutCardSize(Self.shortcuts, columns: 2)
        let origin = CGPoint(x: bounds.width - size.width - 20, y: tabStripBottom + 14)
        // Step aside while the pointer works underneath it.
        if CGRect(origin: origin, size: size).insetBy(dx: -24, dy: -24).contains(pointer) { guideHeaderRect = .zero; return }
        guideHeaderRect = Chrome.drawShortcutCard(Self.shortcuts, origin: origin).header
    }

    // MARK: Recents shelf

    private let cardWidth: CGFloat = 116

    private func cardSize(_ img: NSImage) -> CGSize {
        let aspect = img.size.height / max(1, img.size.width)
        return CGSize(width: cardWidth, height: min(130, max(46, cardWidth * aspect)))
    }

    /// Card frames, front (newest) first, plus their tilt in degrees.
    private func shelfLayout() -> [(CGRect, CGFloat)] {
        let cards = Array(recents.prefix(5))
        guard !cards.isEmpty else { return [] }
        let right = bounds.width - 22
        if shelfOpen {
            let sizes = cards.map { cardSize($0.image) }
            let total = sizes.reduce(0) { $0 + $1.height } + CGFloat(sizes.count - 1) * 10
            var y = bounds.midY - total / 2
            return sizes.map { s in
                defer { y += s.height + 10 }
                return (CGRect(x: right - s.width, y: y, width: s.width, height: s.height), 0)
            }
        }
        let tilts: [CGFloat] = [0, -3, 6, -9, 12]
        return cards.enumerated().map { i, c in
            let s = cardSize(c.image)
            return (CGRect(x: right - s.width - CGFloat(i) * 3, y: bounds.midY - s.height / 2 - CGFloat(i) * 2, width: s.width, height: s.height), tilts[i])
        }
    }

    private func shelfContains(_ p: CGPoint) -> Bool {
        let lay = shelfLayout()
        guard let first = lay.first else { return false }
        let all = lay.dropFirst().reduce(first.0) { $0.union($1.0) }
        return all.insetBy(dx: -16, dy: -16).contains(p)
    }

    private func drawShelf(_ ctx: CGContext) {
        let lay = shelfLayout()
        cardRects = []
        guard !lay.isEmpty else { return }
        if !shelfOpen {
            let first = lay[0].0
            NSAttributedString(string: "Recent", attributes: Chrome.attrs(Chrome.font(10, .semibold), Chrome.dimText))
                .draw(at: CGPoint(x: first.minX, y: first.minY - 30))
        }
        // Back to front so the newest sits on top.
        for i in lay.indices.reversed() {
            let (r, tilt) = lay[i]
            ctx.saveGState()
            ctx.translateBy(x: r.midX, y: r.midY)
            ctx.rotate(by: tilt * .pi / 180)
            let local = CGRect(x: -r.width / 2, y: -r.height / 2, width: r.width, height: r.height)
            ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 12, color: NSColor(white: 0, alpha: 0.5).cgColor)
            let path = CGPath(roundedRect: local, cornerWidth: 8, cornerHeight: 8, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(NSColor(white: 0.15, alpha: 1).cgColor)
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.addPath(path)
            ctx.clip()
            // Top-anchored cover crop.
            let img = recents[i].image
            let k = max(local.width / max(1, img.size.width), local.height / max(1, img.size.height))
            let dw = img.size.width * k, dh = img.size.height * k
            img.draw(in: CGRect(x: local.midX - dw / 2, y: local.minY, width: dw, height: dh), from: .zero,
                     operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            ctx.resetClip()
            ctx.addPath(path)
            let hot = shelfOpen && r.contains(pointer)
            ctx.setStrokeColor((hot ? Chrome.accent : NSColor(white: 1, alpha: 0.35)).cgColor)
            ctx.setLineWidth(hot ? 2.5 : 1)
            ctx.strokePath()
            ctx.restoreGState()
            cardRects.append((i, r))
        }
    }

    private func setShelfOpen(_ open: Bool) {
        shelfFoldWork?.cancel()
        if open {
            shelfOpen = true
        } else if shelfOpen {
            let work = DispatchWorkItem { [weak self] in
                self?.shelfOpen = false
                self?.needsDisplay = true
            }
            shelfFoldWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    // MARK: Mouse

    private func loc(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseMoved(with e: NSEvent) {
        pointer = loc(e)
        NSCursor.crosshair.set()
        setShelfOpen(shelfContains(pointer))
        updateHover()
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        let p = loc(e)
        pointer = p
        for (m, r) in tabRects where r.contains(p) {
            setMode(m)
            return
        }
        if annotateRect.contains(p) {
            annotate.toggle()
            needsDisplay = true
            return
        }
        if guideHeaderRect.contains(p) {
            Chrome.guideHidden = true
            needsDisplay = true
            return
        }
        if shelfContains(p) {
            for (i, r) in cardRects.reversed() where r.contains(p) && shelfOpen {
                finish?(.recent(recents[i].entry))
                return
            }
            return
        }
        dragStart = p
        dragging = false
    }

    override func mouseDragged(with e: NSEvent) {
        pointer = loc(e)
        if let s = dragStart, !dragging, s.distance(to: pointer) > 3, mode != .window, mode != .fullscreen {
            dragging = true
            pending = nil
            hovered = nil
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        pointer = loc(e)
        defer {
            dragStart = nil
            dragging = false
            needsDisplay = true
        }
        if dragging, let r = selectionRect?.integral {
            guard r.width >= 4, r.height >= 4 else { return }
            remember(r)
            if mode == .scroll {
                finish?(.scroll(r, annotate: annotate))
            } else {
                finish?(.selected(CaptureSelection(rect: r, app: appUnder(r)), annotate: annotate))
            }
            return
        }
        guard dragStart != nil else { return }
        if let p = pending, p.contains(pointer) {
            confirmPending()
            return
        }
        switch mode {
        case .smart, .window:
            if let h = hovered {
                finish?(.selected(CaptureSelection(rect: h.frame, app: h.app), annotate: annotate))
            } else if mode == .smart {
                finish?(.selected(CaptureSelection(rect: bounds, app: nil), annotate: annotate))
            }
        case .fullscreen:
            finish?(.selected(CaptureSelection(rect: bounds, app: nil), annotate: annotate))
        case .region, .scroll:
            break
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if dragging {
            dragging = false
            dragStart = nil
            needsDisplay = true
        } else {
            finish?(.cancelled)
        }
    }

    private func appUnder(_ r: CGRect) -> String? {
        snap.windows.first { $0.frame.contains(r.center) }?.app
    }

    private func setMode(_ m: CaptureMode) {
        mode = m
        pending = nil
        updateHover()
        needsDisplay = true
    }

    private func confirmPending() {
        guard let p = pending else { return }
        if mode == .scroll {
            finish?(.scroll(p, annotate: annotate))
        } else {
            finish?(.selected(CaptureSelection(rect: p, app: appUnder(p)), annotate: annotate))
        }
    }

    // MARK: Region memory

    private var memoryKey: String { "lastRegion.\(snap.displayID)" }

    private func remember(_ r: CGRect) {
        UserDefaults.standard.set([r.minX, r.minY, r.width, r.height, bounds.width, bounds.height], forKey: memoryKey)
    }

    private func restoreRegion() {
        guard let v = UserDefaults.standard.array(forKey: memoryKey) as? [Double], v.count == 6,
              v[4] == bounds.width, v[5] == bounds.height else {
            NSSound.beep()
            return
        }
        let r = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        guard bounds.contains(r) else { return }
        pending = r
        needsDisplay = true
    }

    // MARK: Keys

    override func keyDown(with e: NSEvent) {
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let cmd = e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control)
        switch e.keyCode {
        case 53: // Esc
            if dragging {
                dragging = false
                dragStart = nil
                needsDisplay = true
            } else if pending != nil {
                pending = nil
                needsDisplay = true
            } else {
                finish?(.cancelled)
            }
            return
        case 48: // Tab
            let all = Aspect.allCases
            let i = all.firstIndex(of: aspect)!
            aspect = all[(i + (e.modifierFlags.contains(.shift) ? all.count - 1 : 1)) % all.count]
            needsDisplay = true
            return
        case 36, 76: // Return
            if pending != nil { confirmPending() } else if let h = hovered {
                finish?(.selected(CaptureSelection(rect: h.frame, app: h.app), annotate: annotate))
            }
            return
        case 123, 124, 125, 126:
            if cmd { moveHover(e.keyCode) }
            return
        default: break
        }
        if cmd, chars == "a" {
            finish?(.selected(CaptureSelection(rect: bounds, app: nil), annotate: annotate))
            return
        }
        guard !cmd else { return }
        switch chars {
        case "s": setMode(mode == .scroll ? .smart : .scroll)
        case "e", "a": annotate.toggle(); needsDisplay = true
        case "r": restoreRegion()
        case "w": setMode(mode == .window ? .smart : .window)
        case "?", "/": Chrome.guideHidden.toggle(); needsDisplay = true
        default: break
        }
    }

    private func moveHover(_ key: UInt16) {
        if mode != .window && mode != .smart { setMode(.window) }
        let from = hovered?.frame.center ?? pointer
        let dir: CGPoint = switch key {
        case 123: CGPoint(x: -1, y: 0)
        case 124: CGPoint(x: 1, y: 0)
        case 125: CGPoint(x: 0, y: 1)
        default: CGPoint(x: 0, y: -1)
        }
        let candidates = snap.windows.filter { $0.windowID != hovered?.windowID }.compactMap { w -> (WindowInfo, CGFloat)? in
            let d = w.frame.center - from
            let along = d.x * dir.x + d.y * dir.y
            guard along > 1 else { return nil }
            let across = abs(d.x * dir.y - d.y * dir.x)
            return (w, along + across * 2)
        }
        if let best = candidates.min(by: { $0.1 < $1.1 })?.0 {
            hovered = best
            pointer = best.frame.center
            needsDisplay = true
        }
    }
}
