import AppKit
import MacSnapCore

/// A floating capture preview. Unpinned previews fade after an idle timeout;
/// pinned ones stay until closed.
@MainActor
final class PreviewCard: NSObject {
    let shot: Shot
    private(set) var pinned: Bool
    let panel: PreviewPanel
    let view: PreviewCardView
    var screen: NSScreen
    /// Dragged clear of the stack: left alone by stack layout.
    var freePlaced = false
    weak var stack: PreviewStack?
    var busy = 0 { didSet { updateCountdown() } }
    private var countdown: Timer?
    private var fading = false
    private(set) var closed = false
    var tilt: CGFloat = 0 { didSet { view.tilt = tilt } }

    static let width: CGFloat = 200
    static let margin: CGFloat = 26

    var cardSize: CGSize {
        let img = shot.flat
        let w = CGFloat(img?.width ?? 1), h = CGFloat(img?.height ?? 1)
        return CGSize(width: Self.width, height: min(400, max(50, Self.width * h / max(1, w))).rounded())
    }

    var panelSize: CGSize { CGSize(width: cardSize.width + 2 * Self.margin, height: cardSize.height + 2 * Self.margin) }

    init(shot: Shot, screen: NSScreen, pinned: Bool) {
        self.shot = shot
        self.screen = screen
        self.pinned = pinned
        panel = PreviewPanel(frame: CGRect(origin: .zero, size: CGSize(width: 100, height: 100)), level: .floating)
        view = PreviewCardView(frame: .zero)
        super.init()
        panel.setContentSize(panelSize)
        view.frame = CGRect(origin: .zero, size: panelSize)
        view.card = self
        panel.contentView = view
        panel.card = self
        refreshImage()
    }

    func refreshImage() {
        if let flat = shot.flat, let thumb = ImageFiles.thumbnail(flat, maxPixel: 900) {
            view.image = NSImage(cgImage: thumb, size: CGSize(width: thumb.width, height: thumb.height))
        }
        let size = panelSize
        if panel.frame.size != size {
            var f = panel.frame
            f.origin.y += f.height - size.height
            f.size = size
            panel.setFrame(f, display: true)
            view.frame = CGRect(origin: .zero, size: size)
        }
        view.needsDisplay = true
    }

    func show(at frame: CGRect) {
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        updateCountdown()
    }

    func setPinned(_ p: Bool) {
        pinned = p
        view.needsDisplay = true
        view.updateControls()
        updateCountdown()
    }

    func updateCountdown() {
        countdown?.invalidate()
        countdown = nil
        if fading, pinned || busy > 0 || view.hovered {
            fading = false
            panel.animator().alphaValue = 1
        }
        guard !pinned, busy == 0, !view.hovered, !closed else { return }
        let seconds = AppController.shared.config.previewSeconds
        countdown = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expire() }
        }
    }

    private func expire() {
        guard !pinned, busy == 0, !view.hovered else { return }
        fading = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fading else { return }
                self.close(focusNext: false)
            }
        })
    }

    func close(focusNext: Bool = true) {
        guard !closed else { return }
        closed = true
        countdown?.invalidate()
        panel.orderOut(nil)
        stack?.remove(self, focusNext: focusNext)
    }

    // MARK: Actions

    func copyImage() {
        guard let flat = shot.flat else { return }
        busy += 1
        let scale = shot.scale
        Task.detached {
            let data = ImageFiles.pngData(flat, scale: scale)
            await MainActor.run {
                if let data { Output.copyPNG(data) }
                self.busy -= 1
                self.view.flash("Copied")
            }
        }
    }

    /// Saves to the screenshots directory if the shot has no file yet.
    func ensureSaved(_ then: @escaping (URL?) -> Void) {
        if let u = shot.savedURL, FileManager.default.fileExists(atPath: u.path) { return then(u) }
        guard let flat = shot.flat else { return then(nil) }
        busy += 1
        let url = AppController.shared.config.outputURL(app: shot.app)
        let scale = shot.scale
        Task.detached {
            let ok = (try? ImageFiles.writePNG(flat, scale: scale, to: url)) != nil
            await MainActor.run {
                self.busy -= 1
                if ok { self.shot.savedURL = url }
                then(ok ? url : nil)
            }
        }
    }

    func copyPath() {
        ensureSaved { [weak self] url in
            guard let url else { return }
            Output.copyText(url.path)
            self?.view.flash("Path copied")
        }
    }

    func reveal() {
        ensureSaved { url in
            if let url { Output.reveal(url) }
        }
    }

    func edit() {
        AppController.shared.edit(card: self)
    }

    func togglePin() { setPinned(!pinned) }

    /// A file for drag-out: the saved PNG, or a private temporary one.
    func dragFileURL() -> URL? {
        if let u = shot.savedURL, FileManager.default.fileExists(atPath: u.path) { return u }
        guard let flat = shot.flat else { return nil }
        let name = AppController.shared.config.outputURL(app: shot.app).lastPathComponent
        let dir = Output.runtimeDir.appendingPathComponent(shot.id, isDirectory: true)
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? ImageFiles.writePNG(flat, scale: shot.scale, to: url)
        }
        return url
    }
}

final class PreviewPanel: KeyPanel {
    weak var card: PreviewCard?

    override func keyDown(with e: NSEvent) {
        guard let card else { return }
        let cmd = e.modifierFlags.contains(.command)
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if e.keyCode == 53 { card.close(); return }
        if cmd {
            switch ch {
            case "c": card.copyImage()
            case "p": card.togglePin()
            case "w": card.close()
            default: super.keyDown(with: e)
            }
            return
        }
        switch ch {
        case "t": card.togglePin()
        case "a", "e": card.edit()
        case "l", "f": card.copyPath()
        case "r": card.reveal()
        case "c": card.copyImage()
        case "x": card.close()
        default: super.keyDown(with: e)
        }
    }
}

final class PreviewCardView: NSView, NSDraggingSource {
    weak var card: PreviewCard?
    var image: NSImage?
    var tilt: CGFloat = 0 { didSet { needsDisplay = true; updateControls() } }
    private(set) var hovered = false
    private var flashText: String?
    private var dragStartScreen: CGPoint?
    private var dragStartOrigin: CGPoint?
    private var draggingWindow = false
    private var controls: [HUDButton] = []
    private var pinButton: HUDButton!
    private var handleRect: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        autoresizesSubviews = false
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        let edit = HUDButton(symbol: "square.and.pencil", tip: "Annotate · A", size: CGSize(width: 76, height: 30)) { [weak self] in self?.card?.edit() }
        edit.label = "Edit"
        let copy = HUDButton(symbol: "doc.on.doc", tip: "Copy · C", size: CGSize(width: 80, height: 30)) { [weak self] in self?.card?.copyImage() }
        copy.label = "Copy"
        pinButton = HUDButton(symbol: "pin", tip: "Keep on screen · T", size: CGSize(width: 26, height: 26)) { [weak self] in self?.card?.togglePin() }
        let close = HUDButton(symbol: "xmark", tip: "Close · X", size: CGSize(width: 26, height: 26)) { [weak self] in self?.card?.close() }
        let link = HUDButton(symbol: "link", tip: "Copy file path · L", size: CGSize(width: 26, height: 26)) { [weak self] in self?.card?.copyPath() }
        let folder = HUDButton(symbol: "folder", tip: "Show in Finder · R", size: CGSize(width: 26, height: 26)) { [weak self] in self?.card?.reveal() }
        controls = [edit, copy, pinButton, close, link, folder]
        controls.forEach { addSubview($0) }
        updateControls()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var cardRect: CGRect { bounds.insetBy(dx: PreviewCard.margin, dy: PreviewCard.margin) }

    override func layout() {
        super.layout()
        updateControls()
    }

    func updateControls() {
        let r = cardRect
        let show = hovered && abs(tilt) < 0.01
        let edit = controls[0], copy = controls[1], close = controls[3], link = controls[4], folder = controls[5]
        let center = r.height >= 74 ? CGPoint(x: r.midX, y: r.midY + 6) : CGPoint(x: r.midX, y: r.midY)
        edit.frame = CGRect(x: center.x - 76 - 3, y: center.y - 15, width: 76, height: 30)
        copy.frame = CGRect(x: center.x + 3, y: center.y - 15, width: 80, height: 30)
        close.frame = CGRect(x: r.maxX - 30, y: r.minY + 4, width: 26, height: 26)
        pinButton.frame = CGRect(x: r.maxX - 58, y: r.minY + 4, width: 26, height: 26)
        handleRect = CGRect(x: r.minX + 4, y: r.minY + 4, width: 22, height: 26)
        link.frame = CGRect(x: r.minX + 28, y: r.minY + 4, width: 26, height: 26)
        folder.frame = CGRect(x: r.minX + 54, y: r.minY + 4, width: 26, height: 26)
        let compact = r.height < 74
        for (i, c) in controls.enumerated() {
            c.isHidden = !show || (compact && (i == 4 || i == 5))
        }
        pinButton.symbol = card?.pinned == true ? "pin.fill" : "pin"
        pinButton.active = card?.pinned == true
    }

    func flash(_ s: String) {
        flashText = s
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            self?.flashText = nil
            self?.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = cardRect
        ctx.saveGState()
        ctx.translateBy(x: r.midX, y: r.midY)
        ctx.rotate(by: tilt * .pi / 180)
        let local = CGRect(x: -r.width / 2, y: -r.height / 2, width: r.width, height: r.height)
        let path = CGPath(roundedRect: local, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 18, color: NSColor(white: 0, alpha: 0.45).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if let img = image {
            // Top-anchored cover crop.
            let k = max(local.width / max(1, img.size.width), local.height / max(1, img.size.height))
            let dw = img.size.width * k, dh = img.size.height * k
            img.draw(in: CGRect(x: local.midX - dw / 2, y: local.minY, width: dw, height: dh), from: .zero,
                     operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }
        if hovered && abs(tilt) < 0.01 {
            ctx.setFillColor(NSColor(white: 0, alpha: 0.38).cgColor)
            ctx.fill(local)
        }
        ctx.restoreGState()
        ctx.addPath(path)
        let pinned = card?.pinned == true
        ctx.setStrokeColor((pinned ? Chrome.accent : NSColor(white: 1, alpha: 0.28)).cgColor)
        ctx.setLineWidth(pinned ? 2 : 1)
        ctx.strokePath()
        ctx.restoreGState()

        if hovered && abs(tilt) < 0.01 {
            // Six-dot drag handle.
            NSColor(white: 1, alpha: 0.9).setFill()
            for i in 0..<2 {
                for j in 0..<3 {
                    NSBezierPath(ovalIn: CGRect(x: handleRect.midX - 4 + CGFloat(i) * 6, y: handleRect.midY - 7 + CGFloat(j) * 6, width: 3, height: 3)).fill()
                }
            }
        } else if pinned {
            let badge = CGRect(x: r.maxX - 24, y: r.minY + 6, width: 18, height: 18)
            Chrome.accent.setFill()
            NSBezierPath(ovalIn: badge).fill()
            Chrome.drawSymbol("pin.fill", in: badge, color: .white, size: 9)
        }
        if let t = flashText {
            Chrome.drawPill(t, center: CGPoint(x: r.midX, y: r.maxY - 18), font: Chrome.font(11, .semibold))
        }
    }

    // MARK: Hover

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        card?.updateCountdown()
        card?.stack?.hoverChanged()
        updateControls()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        card?.updateCountdown()
        card?.stack?.hoverChanged()
        updateControls()
        needsDisplay = true
    }

    // MARK: Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard cardRect.contains(p) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeKey()
        let p = convert(e.locationInWindow, from: nil)
        if hovered, handleRect.contains(p) {
            startFileDrag(e)
            return
        }
        dragStartScreen = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin
        draggingWindow = false
    }

    override func mouseDragged(with e: NSEvent) {
        guard let s = dragStartScreen, let o = dragStartOrigin, let card else { return }
        let m = NSEvent.mouseLocation
        let d = CGPoint(x: m.x - s.x, y: m.y - s.y)
        if !draggingWindow, d.length < 3 { return }
        if !draggingWindow {
            draggingWindow = true
            card.busy += 1
            card.setPinned(true) // dragging keeps it
            card.stack?.beginDrag(card)
        }
        window?.setFrameOrigin(CGPoint(x: o.x + d.x, y: o.y + d.y))
        card.stack?.dragMoved(card)
    }

    override func mouseUp(with e: NSEvent) {
        if draggingWindow, let card {
            card.busy -= 1
            card.stack?.endDrag(card)
        }
        draggingWindow = false
        dragStartScreen = nil
    }

    override func otherMouseDown(with event: NSEvent) {
        card?.close()
    }

    override func scrollWheel(with event: NSEvent) {}

    private func startFileDrag(_ e: NSEvent) {
        guard let card, let url = card.dragFileURL() else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let r = cardRect
        item.setDraggingFrame(CGRect(x: r.minX, y: r.minY, width: min(120, r.width), height: min(120, r.width) * r.height / r.width),
                              contents: image)
        card.busy += 1
        beginDraggingSession(with: [item], event: e, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        card?.busy -= 1
    }
}

/// Lays out previews and pins as a tilted deck in the bottom-right corner of
/// each screen; hovering fans them out into a column.
@MainActor
final class PreviewStack {
    private(set) var cards: [PreviewCard] = [] // newest first
    private var fanned = false
    private var foldWork: DispatchWorkItem?
    private var dragging: PreviewCard?
    static let gap: CGFloat = 14

    func add(_ card: PreviewCard) {
        card.stack = self
        cards.insert(card, at: 0)
        let target = frames(for: card.screen)[card] ?? CGRect(origin: .zero, size: card.panelSize)
        card.show(at: target)
        relayout(animated: true)
    }

    func replace(_ old: PreviewCard?, with card: PreviewCard) {
        if let old, let i = cards.firstIndex(where: { $0 === old }) {
            card.stack = self
            cards.insert(card, at: i)
            old.close(focusNext: false)
            card.show(at: frames(for: card.screen)[card] ?? old.panel.frame)
            relayout(animated: true)
        } else {
            add(card)
        }
    }

    func remove(_ card: PreviewCard, focusNext: Bool) {
        cards.removeAll { $0 === card }
        relayout(animated: true)
        if focusNext, let next = cards.first(where: { $0.screen == card.screen && !$0.freePlaced }) {
            next.panel.makeKey()
        }
    }

    func card(for shotId: String) -> PreviewCard? { cards.first { $0.shot.id == shotId } }

    // MARK: Hover

    func hoverChanged() {
        let any = cards.contains { $0.view.hovered && !$0.freePlaced } || dragging != nil
        foldWork?.cancel()
        if any {
            if !fanned {
                fanned = true
                relayout(animated: true)
            }
        } else if fanned {
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.fanned = false
                self.relayout(animated: true)
            }
            foldWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
        }
    }

    // MARK: Layout

    private func stacked(on screen: NSScreen) -> [PreviewCard] {
        cards.filter { $0.screen == screen && !$0.freePlaced && $0 !== dragging }
    }

    /// Panel frames for every stacked card on `screen`.
    private func frames(for screen: NSScreen) -> [PreviewCard: CGRect] {
        let vis = screen.visibleFrame
        let m = PreviewCard.margin
        var out: [PreviewCard: CGRect] = [:]
        let list = stacked(on: screen)
        if fanned {
            var x = vis.maxX - Self.gap + m
            var y = vis.minY + Self.gap - m
            var colWidth: CGFloat = 0
            for c in list {
                let s = c.panelSize
                if y + s.height - 2 * m > vis.maxY - Self.gap, y > vis.minY + Self.gap - m {
                    x -= colWidth - 2 * m + 12
                    y = vis.minY + Self.gap - m
                    colWidth = 0
                }
                out[c] = CGRect(x: x - s.width, y: y, width: s.width, height: s.height)
                y += s.height - 2 * m + 10
                colWidth = max(colWidth, s.width)
            }
        } else {
            for c in list {
                let s = c.panelSize
                out[c] = CGRect(x: vis.maxX - Self.gap + m - s.width, y: vis.minY + Self.gap - m, width: s.width, height: s.height)
            }
        }
        return out
    }

    func relayout(animated: Bool) {
        let tilts: [CGFloat] = [0, -3, 6, -9, 12, -12, 12]
        for screen in Set(cards.map(\.screen)) {
            let fr = frames(for: screen)
            let list = stacked(on: screen)
            for (i, c) in list.enumerated() {
                guard let f = fr[c] else { continue }
                c.tilt = fanned ? 0 : tilts[min(i, tilts.count - 1)]
                if animated, c.panel.frame != f {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.2
                        ctx.allowsImplicitAnimation = true
                        c.panel.animator().setFrame(f, display: true)
                    }
                } else {
                    c.panel.setFrame(f, display: true)
                }
            }
            // Newest in front.
            for c in list.reversed() { c.panel.orderFrontRegardless() }
        }
    }

    // MARK: Dragging

    func beginDrag(_ card: PreviewCard) {
        dragging = card
        card.tilt = 0
        relayout(animated: true)
    }

    func dragMoved(_ card: PreviewCard) {
        // Open an insertion gap where the card would land.
        guard !card.freePlaced || nearStack(card) else { return }
        reorder(card)
    }

    private func nearStack(_ card: PreviewCard) -> Bool {
        let vis = card.screen.visibleFrame
        let f = card.panel.frame.insetBy(dx: PreviewCard.margin, dy: PreviewCard.margin)
        return f.midX > vis.maxX - PreviewCard.width * 1.6
    }

    private func reorder(_ card: PreviewCard) {
        guard nearStack(card) else { return }
        let list = stacked(on: card.screen)
        let y = card.panel.frame.minY
        var idx = list.count
        let fr = frames(for: card.screen)
        for (i, c) in list.enumerated() where (fr[c]?.minY ?? 0) > y {
            idx = i
            break
        }
        cards.removeAll { $0 === card }
        let insertAt: Int
        if idx < list.count, let anchor = cards.firstIndex(where: { $0 === list[idx] }) { insertAt = anchor } else {
            insertAt = (list.last.flatMap { l in cards.firstIndex(where: { $0 === l }) }.map { $0 + 1 }) ?? cards.count
        }
        cards.insert(card, at: min(insertAt, cards.count))
        relayout(animated: true)
    }

    func endDrag(_ card: PreviewCard) {
        dragging = nil
        // Adopt the screen it was dropped on.
        let center = CGPoint(x: card.panel.frame.midX, y: card.panel.frame.midY)
        if let s = NSScreen.screens.first(where: { $0.frame.contains(center) }) { card.screen = s }
        if nearStack(card) {
            card.freePlaced = false
            reorder(card)
        } else {
            card.freePlaced = true
            // Keep it fully inside the usable area.
            let vis = card.screen.visibleFrame.insetBy(dx: Self.gap - PreviewCard.margin, dy: Self.gap - PreviewCard.margin)
            var f = card.panel.frame
            f.origin.x = min(max(f.origin.x, vis.minX), vis.maxX - f.width)
            f.origin.y = min(max(f.origin.y, vis.minY), vis.maxY - f.height)
            card.panel.animator().setFrame(f, display: true)
        }
        hoverChanged()
        relayout(animated: true)
    }
}
