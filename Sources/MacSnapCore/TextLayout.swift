import AppKit
import CoreText

/// Bundled annotation faces and their layout rules, shared by the editor
/// (live text editing) and the renderer so both agree to the point.
public enum TextLayout {
    public static func register(fontsIn directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension.lowercased() == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    public static func nsFont(_ face: TextFont, size: CGFloat) -> NSFont {
        let s = max(4, size)
        switch face {
        case .neucha:
            return NSFont(name: "Neucha", size: s) ?? NSFont(name: "Marker Felt", size: s) ?? .systemFont(ofSize: s)
        case .mono:
            return NSFont(name: "JetBrainsMono-Regular", size: s) ?? .monospacedSystemFont(ofSize: s, weight: .regular)
        case .inter:
            return NSFont(name: "InterDisplay-SemiBold", size: s) ?? .systemFont(ofSize: s, weight: .semibold)
        }
    }

    public static func label(_ face: TextFont) -> String {
        switch face {
        case .neucha: "Neucha"
        case .mono: "JetBrains Mono"
        case .inter: "Inter Display"
        }
    }

    /// Inner padding between the annotation box edge and its glyphs.
    public static func padding(_ a: Annotation) -> CGSize {
        let size = a.width
        switch a.textStyle {
        case .pill: return CGSize(width: (size * 0.45).rounded(), height: (size * 0.2).rounded())
        case .plain, .outline: return CGSize(width: 2, height: 1)
        }
    }

    public static func textColor(_ a: Annotation) -> RGBA {
        a.color
    }

    public static let pillColor = RGBA(1.0, 0.973, 0.882)

    public static func outlineColor(_ a: Annotation) -> RGBA {
        a.color.luminance > 0.55 ? RGBA(0.08, 0.08, 0.1) : .white
    }

    public static func attributed(_ a: Annotation, text: String? = nil) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineHeightMultiple = a.font == .neucha ? 1.0 : 1.05
        var attrs: [NSAttributedString.Key: Any] = [
            .font: nsFont(a.font, size: a.width),
            .foregroundColor: NSColor(cgColor: textColor(a).cgColor) ?? .black,
            .paragraphStyle: para,
        ]
        if a.textStyle == .outline {
            attrs[.strokeColor] = NSColor(cgColor: outlineColor(a).cgColor)
            attrs[.strokeWidth] = -3.0
        }
        let t = text ?? a.text
        return NSAttributedString(string: t.isEmpty ? " " : t, attributes: attrs)
    }

    /// Size of the laid-out glyphs (without padding).
    public static func textSize(_ a: Annotation, text: String? = nil) -> CGSize {
        let str = attributed(a, text: text)
        let constraint = CGSize(width: a.wrapWidth.map { max(10, $0 - 2 * padding(a).width) } ?? 100_000, height: 100_000)
        let r = str.boundingRect(with: constraint, options: [.usesLineFragmentOrigin, .usesFontLeading])
        let lineH = nsFont(a.font, size: a.width).boundingRectForFont.height
        return CGSize(width: ceil(max(r.width, a.width * 0.3)), height: ceil(max(r.height, lineH * 0.9)))
    }

    /// Full box (including pill padding) in source coordinates.
    public static func box(_ a: Annotation, text: String? = nil) -> CGRect {
        let origin = a.points.first ?? .zero
        let pad = padding(a)
        let ts = textSize(a, text: text)
        let w = a.wrapWidth ?? (ts.width + 2 * pad.width)
        return CGRect(x: origin.x, y: origin.y, width: w, height: ts.height + 2 * pad.height)
    }
}
