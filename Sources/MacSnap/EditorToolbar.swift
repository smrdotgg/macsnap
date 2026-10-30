import AppKit
import MacSnapCore

/// A flat icon button drawn in the HUD style.
final class HUDButton: NSView {
    var symbol: String { didSet { needsDisplay = true } }
    var active = false { didSet { needsDisplay = true } }
    var enabled = true { didSet { needsDisplay = true } }
    var label: String?
    var action: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var customDraw: ((CGRect) -> Void)?
    private var hover = false
    private var pressed = false

    init(symbol: String, tip: String, size: CGSize = CGSize(width: 30, height: 30), action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.action = action
        super.init(frame: CGRect(origin: .zero, size: size))
        toolTip = tip
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        if event.modifierFlags.contains(.control), let menu = menuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        if active {
            Chrome.accent.setFill()
            path.fill()
        } else if pressed {
            NSColor(white: 1, alpha: 0.22).setFill()
            path.fill()
        } else if hover, enabled {
            (label != nil ? Chrome.surfaceRaised : NSColor(white: 1, alpha: 0.12)).setFill()
            path.fill()
        } else if label != nil {
            Chrome.surface.setFill()
            path.fill()
        }
        if let customDraw {
            customDraw(r)
            return
        }
        let color: NSColor = !enabled ? NSColor(white: 1, alpha: 0.28) : (active ? .white : Chrome.text)
        if let label {
            let iconRect = CGRect(x: r.minX + 6, y: r.minY, width: 18, height: r.height)
            Chrome.drawSymbol(symbol, in: iconRect, color: color, size: 13)
            NSAttributedString(string: label, attributes: Chrome.attrs(Chrome.font(12, .semibold), color))
                .draw(at: CGPoint(x: iconRect.maxX + 4, y: r.midY - 8))
        } else {
            Chrome.drawSymbol(symbol, in: r, color: color, size: 14)
        }
    }
}

final class HUDSeparator: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.14).setFill()
        CGRect(x: bounds.midX - 0.5, y: 6, width: 1, height: bounds.height - 12).fill()
    }
}

/// Rounded HUD container that lays out its children in a row.
class HUDBar: NSView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
        Chrome.surface.setFill()
        path.fill()
        Chrome.border.setStroke()
        path.stroke()
    }

    func layoutRow(_ items: [NSView], padding: CGFloat = 4) {
        subviews.forEach { $0.removeFromSuperview() }
        var x = padding
        let h = (items.map(\.frame.height).max() ?? 30) + 2 * padding
        for v in items {
            if v is HUDSeparator {
                v.frame = CGRect(x: x + 2, y: 0, width: 6, height: h)
                x += 10
            } else {
                v.frame.origin = CGPoint(x: x, y: padding)
                x += v.frame.width
            }
            addSubview(v)
        }
        setFrameSize(CGSize(width: x + padding, height: h))
    }

    /// Swallow clicks on the bar background so they don't reach the canvas.
    override func mouseDown(with event: NSEvent) {}
}

final class EditorToolbar: HUDBar {
    weak var editor: EditorView?
    private var toolButtons: [Tool: HUDButton] = [:]
    private var colorButton: HUDButton!
    private var undoButton: HUDButton!
    private var redoButton: HUDButton!

    init(editor: EditorView) {
        self.editor = editor
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        var items: [NSView] = []
        let tools: [Tool] = [.select, .arrow, .line, .pen, .highlighter, .rect, .ellipse, .marker, .text, .redact, .spotlight, .cut]
        for t in tools {
            let b = HUDButton(symbol: t.symbol, tip: "\(t.title) · \(t.key)") { [weak self] in self?.editor?.toolButtonClicked(t) }
            b.menuProvider = { [weak self] in self?.editor?.variantMenu(for: t) }
            toolButtons[t] = b
            items.append(b)
        }
        items.append(HUDSeparator())
        colorButton = HUDButton(symbol: "circle.fill", tip: "Color · 1–8") { [weak self] in
            guard let self else { return }
            self.editor?.showColorPopover(from: self.colorButton)
        }
        colorButton.customDraw = { [weak self] r in
            guard let c = self?.editor?.settings.color else { return }
            let dot = CGRect(x: r.midX - 8, y: r.midY - 8, width: 16, height: 16)
            NSColor(cgColor: c.cgColor)?.setFill()
            NSBezierPath(ovalIn: dot).fill()
            NSColor(white: 1, alpha: 0.85).setStroke()
            let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5))
            ring.lineWidth = 1.5
            ring.stroke()
        }
        items.append(colorButton)
        let bg = HUDButton(symbol: "photo.on.rectangle", tip: "Backdrop & canvas · B / G")
        bg.action = { [weak self, weak bg] in
            guard let self, let bg, let menu = self.editor?.backgroundMenu() else { return }
            menu.popUp(positioning: nil, at: CGPoint(x: 0, y: bg.bounds.height + 4), in: bg)
        }
        items.append(bg)
        items.append(HUDButton(symbol: Tool.ocr.symbol, tip: "Recognize & copy text · O (drag a region with the OCR tool)") { [weak self] in
            self?.editor?.toolButtonClicked(.ocr)
        })
        items.append(HUDSeparator())
        undoButton = HUDButton(symbol: "arrow.uturn.backward", tip: "Undo · ⌘Z") { [weak self] in self?.editor?.undo() }
        redoButton = HUDButton(symbol: "arrow.uturn.forward", tip: "Redo · ⇧⌘Z") { [weak self] in self?.editor?.redo() }
        items += [undoButton, redoButton, HUDSeparator()]
        items.append(HUDButton(symbol: "doc.on.doc", tip: "Copy · ⌘C") { [weak self] in self?.editor?.controller?.perform(.copy) })
        items.append(HUDButton(symbol: "square.and.arrow.down", tip: "Save · ⌘S   (Save As · ⇧⌘S)") { [weak self] in self?.editor?.controller?.perform(.save) })
        let both = HUDButton(symbol: "square.and.arrow.down.on.square", tip: "Copy and save · Return") { [weak self] in self?.editor?.controller?.perform(.copyAndSave) }
        items.append(both)
        items.append(HUDButton(symbol: "pin", tip: "Pin on screen · P") { [weak self] in self?.editor?.controller?.perform(.pin) })
        items.append(HUDButton(symbol: "xmark", tip: "Close · Esc") { [weak self] in self?.editor?.controller?.perform(.dismiss) })
        layoutRow(items)
        refresh()
    }

    func refresh() {
        guard let editor else { return }
        for (t, b) in toolButtons {
            b.active = editor.tool == t
            switch t {
            case .cut: b.symbol = editor.cutInsertArmed ? "plus.square.dashed" : "scissors"
            case .rect: b.symbol = editor.settings.shapeFilled ? "rectangle.fill" : "rectangle"
            case .ellipse: b.symbol = editor.settings.shapeFilled ? "circle.fill" : "circle"
            case .arrow:
                b.symbol = switch editor.settings.arrowStyle {
                case .standard: "arrow.up.right"
                case .pointy: "location.north.fill"
                case .curved: "arrow.turn.up.right"
                case .double: "arrow.left.and.right"
                }
            case .redact: b.symbol = editor.settings.redactStyle == .solid ? "rectangle.fill" : "checkerboard.rectangle"
            case .highlighter: b.symbol = "highlighter"
            default: break
            }
            b.toolTip = "\(t.title)\(editor.variantDescription(t)) · \(t.key)"
        }
        undoButton.enabled = editor.canUndo
        redoButton.enabled = editor.canRedo
        colorButton.needsDisplay = true
    }
}

/// Palette swatches, custom color, and the eyedropper.
final class ColorPickerView: NSView {
    var onPick: ((RGBA) -> Void)?
    var onEyedropper: (() -> Void)?
    var onMore: (() -> Void)?
    let palette: [RGBA]
    let current: RGBA
    let custom: RGBA

    init(palette: [RGBA], current: RGBA, custom: RGBA) {
        self.palette = palette
        self.current = current
        self.custom = custom
        super.init(frame: CGRect(x: 0, y: 0, width: 4 * 34 + 16, height: 2 * 34 + 52))
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func swatchRect(_ i: Int) -> CGRect {
        CGRect(x: 8 + CGFloat(i % 4) * 34, y: 8 + CGFloat(i / 4) * 34, width: 30, height: 30)
    }

    private var customRect: CGRect { CGRect(x: 8, y: 82, width: 64, height: 30) }
    private var dropperRect: CGRect { CGRect(x: 76, y: 82, width: 32, height: 30) }
    private var moreRect: CGRect { CGRect(x: 112, y: 82, width: 32, height: 30) }

    override func draw(_ dirtyRect: NSRect) {
        for (i, c) in palette.enumerated() {
            let r = swatchRect(i).insetBy(dx: 4, dy: 4)
            NSColor(cgColor: c.cgColor)?.setFill()
            NSBezierPath(ovalIn: r).fill()
            NSColor(white: 0.5, alpha: 0.6).setStroke()
            NSBezierPath(ovalIn: r).stroke()
            if c == current {
                Chrome.accent.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -3, dy: -3))
                ring.lineWidth = 2
                ring.stroke()
            }
            NSAttributedString(string: "\(i + 1)", attributes: Chrome.attrs(Chrome.font(8, .bold), NSColor(white: 0.5, alpha: 1)))
                .draw(at: CGPoint(x: r.maxX - 2, y: r.maxY - 6))
        }
        let cr = customRect
        let p = NSBezierPath(roundedRect: cr.insetBy(dx: 2, dy: 4), xRadius: 6, yRadius: 6)
        NSColor(cgColor: custom.cgColor)?.setFill()
        p.fill()
        NSAttributedString(string: "Custom", attributes: Chrome.attrs(Chrome.font(10, .semibold), custom.luminance > 0.6 ? .black : .white))
            .draw(at: CGPoint(x: cr.minX + 12, y: cr.midY - 7))
        Chrome.drawSymbol("eyedropper", in: dropperRect, color: .labelColor, size: 14)
        Chrome.drawSymbol("circle.lefthalf.filled", in: moreRect, color: .labelColor, size: 14)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for i in palette.indices where swatchRect(i).contains(p) {
            onPick?(palette[i])
            return
        }
        if customRect.contains(p) { onPick?(custom) }
        if dropperRect.contains(p) { onEyedropper?() }
        if moreRect.contains(p) { onMore?() }
    }
}
