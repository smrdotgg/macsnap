import AppKit
@testable import MacSnapCore
import XCTest

/// Stitching a realistic page: text lines, blank gaps, repeated rules, and a
/// sticky header, at Retina scale.
final class StitchTextTests: XCTestCase {
    func page(width: Int, height: Int) -> CGImage {
        let ctx = CaptureRenderer.makeContext(width: width, height: height)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        var y = height - 40
        var n = 0
        let words = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed", "do", "eiusmod"]
        while y > 20 {
            n += 1
            if n % 7 == 0 {
                ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
                ctx.fill(CGRect(x: 20, y: y, width: width - 40, height: 2)) // repeated rule
                y -= 30
                continue
            }
            let line = (0..<8).map { words[($0 * 7 + n * 3) % words.count] }.joined(separator: " ") + " \(n)"
            NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 26)]).draw(at: CGPoint(x: 24, y: y))
            y -= n % 5 == 0 ? 70 : 40
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    func testRetinaTextPage() {
        let w = 700, frameH = 500, header = 60
        let full = page(width: w, height: 4000)
        let bar = CaptureRenderer.makeContext(width: w, height: header)!
        bar.setFillColor(CGColor(srgbRed: 0.1, green: 0.3, blue: 0.8, alpha: 1))
        bar.fill(CGRect(x: 0, y: 0, width: w, height: header))
        bar.setFillColor(CGColor(gray: 1, alpha: 1))
        bar.fill(CGRect(x: 30, y: 20, width: 200, height: 20))
        let headerImg = bar.makeImage()!
        func frame(_ y: Int) -> CGImage {
            let ctx = CaptureRenderer.makeContext(width: w, height: frameH)!
            ctx.draw(full.cropping(to: CGRect(x: 0, y: y, width: w, height: frameH))!, in: CGRect(x: 0, y: 0, width: w, height: frameH))
            ctx.draw(headerImg, in: CGRect(x: 0, y: frameH - header, width: w, height: header))
            return ctx.makeImage()!
        }
        let s = Stitcher()
        var y = 0
        s.add(frame(0))
        // Uneven scroll steps, all even pixel counts (Retina points).
        for step in [120, 240, 36, 300, 200, 158, 260, 2, 330] {
            y += step
            XCTAssertEqual(s.add(frame(y)), .moved(step), "step \(step) at \(y)")
        }
        XCTAssertEqual(s.add(frame(y)), .unchanged)
        let out = s.compose()!
        XCTAssertEqual(out.height, y + frameH)
        for r in stride(from: header + 5, to: out.height - 5, by: 97) {
            XCTAssertEqual(pixel(out, 300, r), pixel(full, 300, r), "row \(r)")
        }
    }
}
