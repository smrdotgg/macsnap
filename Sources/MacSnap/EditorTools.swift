import AppKit
import MacSnapCore

enum Tool: String, CaseIterable {
    case select, arrow, line, pen, highlighter, rect, ellipse, marker, text, redact, spotlight, cut, ocr, eyedropper

    var key: String {
        switch self {
        case .select: "V"
        case .arrow: "A"
        case .line: "L"
        case .pen: "F"
        case .highlighter: "H"
        case .rect: "R"
        case .ellipse: "E"
        case .marker: "C"
        case .text: "T"
        case .redact: "D"
        case .spotlight: "S"
        case .cut: "X"
        case .ocr: "O"
        case .eyedropper: "I"
        }
    }

    var title: String {
        switch self {
        case .select: "Select / move"
        case .arrow: "Arrow"
        case .line: "Line"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .rect: "Rectangle"
        case .ellipse: "Ellipse"
        case .marker: "Numbered marker"
        case .text: "Text"
        case .redact: "Redact"
        case .spotlight: "Spotlight"
        case .cut: "Cut out a band"
        case .ocr: "Recognize text"
        case .eyedropper: "Eyedropper"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .marker: "1.circle"
        case .text: "textformat"
        case .redact: "checkerboard.rectangle"
        case .spotlight: "scope"
        case .cut: "scissors"
        case .ocr: "text.viewfinder"
        case .eyedropper: "eyedropper"
        }
    }

    /// Tools that create a vector layer.
    var creates: Bool {
        [.arrow, .line, .pen, .highlighter, .rect, .ellipse, .marker, .text, .redact, .spotlight].contains(self)
    }

    var annotationKind: AnnotationKind? {
        switch self {
        case .arrow: .arrow
        case .line: .line
        case .pen: .pen
        case .highlighter: .highlighter
        case .rect: .rect
        case .ellipse: .ellipse
        case .marker: .marker
        case .text: .text
        case .redact: .redact
        case .spotlight: .spotlight
        default: nil
        }
    }
}

/// Per-session tool settings: the "next layer" each tool will create.
struct ToolSettings {
    var color: RGBA
    var palette: [RGBA]
    var customColor: RGBA
    var arrowStyle: ArrowStyle = .standard
    var shapeFilled = false
    var cornerRadius: Double = 0
    var redactStyle: RedactStyle = .pixelate
    var spotlightShape: SpotlightShape = .ellipse
    var spotlightBorder: Double = 0
    var textFont: TextFont = .neucha
    var textStyle: TextStyle = .pill
    var highlighterSnap = true
    var smoothing = 3
    var sizes: [AnnotationKind: Double] = [
        .arrow: 5, .line: 4, .pen: 4, .highlighter: 18, .rect: 4, .ellipse: 4, .marker: 28, .text: 22,
    ]

    func size(_ k: AnnotationKind) -> Double { sizes[k] ?? 4 }

    func make(_ kind: AnnotationKind, id: Int) -> Annotation {
        var a = Annotation(id: id, kind: kind)
        a.color = color
        a.width = size(kind)
        a.arrowStyle = arrowStyle
        a.filled = shapeFilled
        a.cornerRadius = kind == .rect ? cornerRadius : 0
        a.redactStyle = redactStyle
        a.spotlightShape = spotlightShape
        a.font = textFont
        a.textStyle = textStyle
        a.smoothing = smoothing
        a.seed = UInt64.random(in: 1...UInt64.max)
        if kind == .spotlight {
            a.width = spotlightBorder
            a.magnification = 1
        }
        return a
    }

    static func sizeRange(_ k: AnnotationKind) -> ClosedRange<Double> {
        switch k {
        case .marker: 14...120
        case .text: 8...160
        case .highlighter: 4...80
        default: 1...40
        }
    }
}
