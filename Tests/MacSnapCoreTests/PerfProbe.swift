import CoreGraphics
import Foundation
@testable import MacSnapCore
import XCTest

final class PerfProbe: XCTestCase {
    func testSceneDrawCost5K() throws {
        guard ProcessInfo.processInfo.environment["MACSNAP_PERF"] != nil else { throw XCTSkip("perf probe") }
        let src = fixtureImage(width: 5120, height: 2880)
        var doc = SnapDocument(source: src, scale: 2, crop: CGRect(x: 200, y: 200, width: 1800, height: 1000))
        for i in 0..<30 {
            var a = Annotation(id: i + 1, kind: i % 3 == 0 ? .arrow : (i % 3 == 1 ? .rect : .text))
            a.points = [CGPoint(x: 300 + i * 40, y: 300), CGPoint(x: 500 + i * 30, y: 600)]
            a.rect = CGRect(x: 300 + i * 30, y: 400, width: 120, height: 80)
            a.text = "label \(i)"
            doc.push(.add(a))
        }
        var r = Annotation(id: 99, kind: .redact); r.rect = CGRect(x: 600, y: 600, width: 400, height: 200); doc.push(.add(r))
        let ctx = CaptureRenderer.makeContext(width: 5120, height: 2880)!
        ctx.translateBy(x: 0, y: 2880); ctx.scaleBy(x: 2, y: -2)
        let lay = CaptureRenderer.layout(doc.state)
        let t0 = Date()
        for _ in 0..<20 {
            CaptureRenderer.drawScene(ctx: ctx, layout: lay, source: src, scale: 2, state: doc.state, customBackground: nil)
        }
        print("PERF drawScene avg ms:", Date().timeIntervalSince(t0) / 20 * 1000)
    }
}
