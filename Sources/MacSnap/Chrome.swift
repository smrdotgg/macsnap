import AppKit

/// Shared look for every overlay: dark HUD surfaces, the system accent for
/// selection, and the system font for chrome text.
enum Chrome {
    static let surface = NSColor(calibratedWhite: 0.10, alpha: 0.92)
    static let surfaceRaised = NSColor(calibratedWhite: 0.18, alpha: 0.96)
    static let border = NSColor(calibratedWhite: 1, alpha: 0.13)
    static let text = NSColor(calibratedWhite: 0.96, alpha: 1)
    static let dimText = NSColor(calibratedWhite: 0.62, alpha: 1)
    static let scrim = NSColor(calibratedWhite: 0, alpha: 0.38)
    static var accent: NSColor { .controlAccentColor }

    static func font(_ size: CGFloat = 12, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat = 11, _ weight: NSFont.Weight = .medium) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    static func attrs(_ font: NSFont, _ color: NSColor = text) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    /// A rounded label; returns its frame. `anchor` is the pill's center.
    @discardableResult
    static func drawPill(_ text: String, center: CGPoint, font: NSFont = font(12, .medium), color: NSColor = Chrome.text,
                         background: NSColor = surface, padding: CGSize = CGSize(width: 12, height: 6)) -> CGRect {
        let s = NSAttributedString(string: text, attributes: attrs(font, color))
        let size = s.size()
        let r = CGRect(x: center.x - size.width / 2 - padding.width, y: center.y - size.height / 2 - padding.height,
                       width: size.width + 2 * padding.width, height: size.height + 2 * padding.height).integral
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        background.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
        s.draw(at: CGPoint(x: r.minX + padding.width, y: r.minY + padding.height - 0.5))
        return r
    }

    static func pillSize(_ text: String, font: NSFont = font(12, .medium), padding: CGSize = CGSize(width: 12, height: 6)) -> CGSize {
        let s = NSAttributedString(string: text, attributes: attrs(font)).size()
        return CGSize(width: ceil(s.width + 2 * padding.width), height: ceil(s.height + 2 * padding.height))
    }

    // MARK: Shortcut card

    struct Shortcut {
        var keys: String
        var action: String
    }

    static let cardTitle = "Shortcuts"

    static func shortcutCardSize(_ rows: [Shortcut], columns: Int) -> CGSize {
        let keyFont = mono(11, .semibold), textFont = font(11.5)
        let perCol = Int(ceil(Double(rows.count) / Double(columns)))
        var colWidths: [CGFloat] = []
        for c in 0..<columns {
            let slice = rows.dropFirst(c * perCol).prefix(perCol)
            let kw = slice.map { NSAttributedString(string: $0.keys, attributes: attrs(keyFont)).size().width }.max() ?? 0
            let aw = slice.map { NSAttributedString(string: $0.action, attributes: attrs(textFont)).size().width }.max() ?? 0
            colWidths.append(kw + 12 + aw)
        }
        let w = colWidths.reduce(0, +) + CGFloat(columns - 1) * 24 + 28
        let h = CGFloat(perCol) * 19 + 46
        return CGSize(width: ceil(w), height: ceil(h))
    }

    /// Draws a keycap legend in a flipped view; returns its frame and the
    /// header frame (click to close).
    @discardableResult
    static func drawShortcutCard(_ rows: [Shortcut], origin: CGPoint, columns: Int = 2) -> (card: CGRect, header: CGRect) {
        let size = shortcutCardSize(rows, columns: columns)
        let r = CGRect(origin: origin, size: size)
        let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        surface.setFill()
        path.fill()
        border.setStroke()
        path.stroke()
        let header = CGRect(x: r.minX, y: r.minY, width: r.width, height: 30)
        NSAttributedString(string: cardTitle, attributes: attrs(font(11, .semibold), dimText))
            .draw(at: CGPoint(x: r.minX + 14, y: r.minY + 10))
        NSAttributedString(string: "?", attributes: attrs(mono(11, .semibold), dimText))
            .draw(at: CGPoint(x: r.maxX - 22, y: r.minY + 10))
        let keyFont = mono(11, .semibold), textFont = font(11.5)
        let perCol = Int(ceil(Double(rows.count) / Double(columns)))
        var x = r.minX + 14
        for c in 0..<columns {
            let slice = Array(rows.dropFirst(c * perCol).prefix(perCol))
            let kw = slice.map { NSAttributedString(string: $0.keys, attributes: attrs(keyFont)).size().width }.max() ?? 0
            let aw = slice.map { NSAttributedString(string: $0.action, attributes: attrs(textFont)).size().width }.max() ?? 0
            for (i, row) in slice.enumerated() {
                let y = r.minY + 32 + CGFloat(i) * 19
                NSAttributedString(string: row.keys, attributes: attrs(keyFont, accent.blended(withFraction: 0.35, of: .white) ?? accent))
                    .draw(at: CGPoint(x: x, y: y))
                NSAttributedString(string: row.action, attributes: attrs(textFont, text)).draw(at: CGPoint(x: x + kw + 12, y: y))
            }
            x += kw + 12 + aw + 24
        }
        return (r, header)
    }

    static var guideHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "shortcutGuideHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "shortcutGuideHidden") }
    }

    // MARK: Icons

    static func symbol(_ name: String, size: CGFloat = 14, weight: NSFont.Weight = .medium) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    /// Draws an SF Symbol tinted, centered in `rect`.
    static func drawSymbol(_ name: String, in rect: CGRect, color: NSColor, size: CGFloat = 14) {
        guard let img = symbol(name, size: size) else { return }
        let tinted = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let s = img.size
        tinted.draw(in: CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// Borderless panel that can take keyboard focus without activating the app.
class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(frame: CGRect, level: NSWindow.Level) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }
}
