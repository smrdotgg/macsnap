import CoreGraphics
import Foundation
@testable import MacSnapCore
import XCTest

/// Writes a visual sample when MACSNAP_SAMPLE_DIR is set (for eyeballing).
final class SampleRenderTests: XCTestCase {
    func testWriteSample() throws {
        guard let dir = ProcessInfo.processInfo.environment["MACSNAP_SAMPLE_DIR"] else { throw XCTSkip("no sample dir") }
        let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Fonts")
        TextLayout.register(fontsIn: fonts.standardized)
        var doc = SnapDocument(source: fixtureImage(width: 1200, height: 800), scale: 2, crop: CGRect(x: 20, y: 20, width: 520, height: 340))
        var id = 1
        func add(_ k: AnnotationKind, _ f: (inout Annotation) -> Void) {
            var a = Annotation(id: id, kind: k); id += 1; f(&a); doc.push(.add(a))
        }
        for (i, s) in ArrowStyle.allCases.enumerated() {
            add(.arrow) { $0.arrowStyle = s; $0.points = [CGPoint(x: 40, y: 60 + Double(i) * 50), CGPoint(x: 200, y: 40 + Double(i) * 50)]; $0.width = 5 }
        }
        add(.rect) { $0.rect = CGRect(x: 240, y: 40, width: 120, height: 70); $0.width = 4; $0.color = RGBA(hex: "#0a84ff")! }
        add(.ellipse) { $0.rect = CGRect(x: 380, y: 40, width: 120, height: 70); $0.width = 4; $0.color = RGBA(hex: "#30d158")! }
        add(.marker) { $0.points = [CGPoint(x: 260, y: 150)]; $0.width = 30; $0.number = 1 }
        add(.marker) { $0.points = [CGPoint(x: 300, y: 150)]; $0.width = 30; $0.number = 2; $0.color = RGBA(hex: "#ffd60a")! }
        add(.text) { $0.points = [CGPoint(x: 340, y: 130)]; $0.text = "Hello, Mac!"; $0.width = 24 }
        add(.text) { $0.points = [CGPoint(x: 340, y: 180)]; $0.text = "Outlined"; $0.width = 26; $0.textStyle = .outline; $0.font = .inter }
        add(.text) { $0.points = [CGPoint(x: 340, y: 230)]; $0.text = "plain mono"; $0.width = 20; $0.textStyle = .plain; $0.font = .mono; $0.color = .black }
        add(.highlighter) { $0.points = [CGPoint(x: 40, y: 270), CGPoint(x: 250, y: 270)]; $0.width = 18; $0.snapped = true; $0.color = RGBA(hex: "#ffd60a")! }
        add(.pen) { $0.points = (0..<60).map { CGPoint(x: 40 + Double($0) * 4, y: 310 + sin(Double($0) / 5) * 15) }; $0.width = 4 }
        add(.redact) { $0.rect = CGRect(x: 280, y: 270, width: 100, height: 60) }
        add(.spotlight) { $0.rect = CGRect(x: 400, y: 260, width: 120, height: 90); $0.magnification = 1.6 }
        add(.arrow) { $0.points = [CGPoint(x: 500, y: 200), CGPoint(x: 600, y: 300)]; $0.width = 5 }
        doc.push(.background(.violet))
        let out = CaptureRenderer.render(source: doc.source, scale: 2, state: doc.state)!
        try ImageFiles.writePNG(out, scale: 2, to: URL(fileURLWithPath: dir).appendingPathComponent("sample.png"))
    }
}
