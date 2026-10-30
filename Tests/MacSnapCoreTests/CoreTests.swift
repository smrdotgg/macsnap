import CoreGraphics
import Foundation
@testable import MacSnapCore
import XCTest

/// A deterministic, textured fixture so stitching has distinctive rows.
func fixtureImage(width: Int, height: Int, seed: UInt64 = 7) -> CGImage {
    let ctx = CaptureRenderer.makeContext(width: width, height: height)!
    var rng = CaptureRenderer.SplitMix64(state: seed)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    var y = 0
    while y < height {
        let h = Int(rng.next() % 9) + 2
        let x = Int(rng.next() % UInt64(max(1, width - 20)))
        let w = Int(rng.next() % UInt64(max(1, width - x))) + 1
        ctx.setFillColor(CGColor(srgbRed: Double(rng.next() % 255) / 255, green: Double(rng.next() % 255) / 255,
                                 blue: Double(rng.next() % 255) / 255, alpha: 1))
        ctx.fill(CGRect(x: x, y: height - y - h, width: w, height: h))
        y += h + Int(rng.next() % 4)
    }
    return ctx.makeImage()!
}

func crop(_ img: CGImage, y: Int, height: Int) -> CGImage {
    img.cropping(to: CGRect(x: 0, y: y, width: img.width, height: height))!
}

func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let ctx = CaptureRenderer.makeContext(width: img.width, height: img.height)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * img.height)
    let o = y * ctx.bytesPerRow + x * 4
    return [p[o], p[o + 1], p[o + 2], p[o + 3]]
}

final class DocumentTests: XCTestCase {
    func makeDoc() -> SnapDocument {
        SnapDocument(source: fixtureImage(width: 400, height: 300), scale: 2, crop: CGRect(x: 10, y: 10, width: 100, height: 80))
    }

    func testUndoRedoReplaysLog() {
        var doc = makeDoc()
        var a = Annotation(id: doc.allocateId(), kind: .rect)
        a.rect = CGRect(x: 20, y: 20, width: 30, height: 30)
        doc.push(.add(a))
        var moved = a
        moved.rect.origin.x = 40
        doc.push(.update(moved))
        XCTAssertEqual(doc.state.annotations.first?.rect.minX, 40)
        doc.undo()
        XCTAssertEqual(doc.state.annotations.first?.rect.minX, 20)
        doc.undo()
        XCTAssertTrue(doc.state.annotations.isEmpty)
        doc.redo()
        doc.redo()
        XCTAssertEqual(doc.state.annotations.first?.rect.minX, 40)
        doc.undo()
        doc.push(.remove([a.id]))
        XCTAssertFalse(doc.canRedo)
        XCTAssertTrue(doc.state.annotations.isEmpty)
    }

    func testLogRoundTrip() throws {
        var doc = makeDoc()
        var a = Annotation(id: doc.allocateId(), kind: .arrow)
        a.points = [CGPoint(x: 1, y: 2), CGPoint(x: 30, y: 40)]
        a.arrowStyle = .curved
        doc.push(.add(a))
        doc.push(.background(.aurora))
        doc.push(.cut(CutBand(axis: .rows, start: 30, end: 40)))
        doc.undo()
        let data = try doc.encodedLog()
        let back = try SnapDocument(source: doc.source, log: SnapDocument.decodeLog(data))
        XCTAssertEqual(back.state, doc.state)
        XCTAssertTrue(back.canRedo)
    }

    func testCutShiftsAnnotationsAndCrop() {
        var doc = makeDoc()
        var a = Annotation(id: 1, kind: .marker)
        a.points = [CGPoint(x: 50, y: 70)]
        doc.push(.add(a))
        doc.push(.cut(CutBand(axis: .rows, start: 30, end: 50)))
        XCTAssertEqual(doc.state.annotations[0].points[0].y, 50)
        XCTAssertEqual(doc.state.crop, CGRect(x: 10, y: 10, width: 100, height: 60))
        let composed = CaptureRenderer.composeCuts(doc.source, scale: 2, cuts: doc.state.cuts)
        XCTAssertEqual(composed.height, 300 - 40)
        // Row 60px (logical 30) of the composed image is source row 100px.
        XCTAssertEqual(pixel(composed, 5, 60), pixel(doc.source, 5, 100))
    }

    func testInsertCutGrowsImage() {
        let src = fixtureImage(width: 100, height: 100)
        let composed = CaptureRenderer.composeCuts(src, scale: 1, cuts: [CutBand(axis: .columns, start: 10, end: 30, insert: true)])
        XCTAssertEqual(composed.width, 120)
        XCTAssertEqual(pixel(composed, 15, 50)[3], 0)
        XCTAssertEqual(pixel(composed, 35, 50), pixel(src, 15, 50))
    }
}

final class RenderTests: XCTestCase {
    func testPlainRenderIsCropAtNativePixels() {
        let doc = SnapDocument(source: fixtureImage(width: 400, height: 300), scale: 2, crop: CGRect(x: 10, y: 10, width: 100, height: 80))
        let out = CaptureRenderer.render(source: doc.source, scale: 2, state: doc.state)!
        XCTAssertEqual(out.width, 200)
        XCTAssertEqual(out.height, 160)
        XCTAssertEqual(pixel(out, 0, 0), pixel(doc.source, 20, 20))
    }

    func testFramedGrowthAddsMat() {
        var doc = SnapDocument(source: fixtureImage(width: 200, height: 200), scale: 1, crop: CGRect(x: 0, y: 0, width: 100, height: 100))
        var a = Annotation(id: 1, kind: .rect)
        a.rect = CGRect(x: 80, y: 20, width: 60, height: 20)
        a.width = 4
        doc.push(.add(a))
        let lay = CaptureRenderer.layout(doc.state)
        XCTAssertTrue(lay.matted)
        XCTAssertEqual(lay.content.maxX, 142 + CaptureRenderer.matMargin)
        XCTAssertEqual(lay.content.minX, 0)
        doc.push(.canvas(.overflow))
        XCTAssertEqual(CaptureRenderer.layout(doc.state).content.maxX, 142)
        doc.push(.canvas(.image))
        XCTAssertEqual(CaptureRenderer.layout(doc.state).content, CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    func testBackdropPadsOutput() {
        var doc = SnapDocument(source: fixtureImage(width: 200, height: 100), scale: 1)
        doc.push(.background(.sunset))
        let lay = CaptureRenderer.layout(doc.state)
        XCTAssertGreaterThan(lay.padding, 0)
        let out = CaptureRenderer.render(source: doc.source, scale: 1, state: doc.state)!
        XCTAssertEqual(out.width, 200 + Int(2 * lay.padding))
        XCTAssertEqual(pixel(out, 1, 1)[3], 255)
    }

    func testRedactionDestroysPixels() {
        let src = fixtureImage(width: 120, height: 120)
        var doc = SnapDocument(source: src, scale: 1)
        var a = Annotation(id: 1, kind: .redact)
        a.rect = CGRect(x: 10, y: 10, width: 80, height: 80)
        a.redactStyle = .solid
        doc.push(.add(a))
        let out = CaptureRenderer.render(source: src, scale: 1, state: doc.state)!
        XCTAssertEqual(Array(pixel(out, 50, 50).prefix(3)), [18, 18, 18])
    }

    func testEveryKindRenders() {
        var doc = SnapDocument(source: fixtureImage(width: 300, height: 300), scale: 2)
        let kinds: [AnnotationKind] = [.arrow, .line, .pen, .highlighter, .rect, .ellipse, .marker, .text, .redact, .spotlight]
        for (i, k) in kinds.enumerated() {
            var a = Annotation(id: i + 1, kind: k)
            a.points = [CGPoint(x: 10, y: 10 + Double(i) * 10), CGPoint(x: 90, y: 30 + Double(i) * 10), CGPoint(x: 100, y: 40)]
            a.rect = CGRect(x: 20, y: 20, width: 40, height: 30)
            a.text = "Hello"
            a.magnification = 2
            doc.push(.add(a))
        }
        for s in ArrowStyle.allCases {
            var a = Annotation(id: 100 + s.hashValue % 50, kind: .arrow)
            a.arrowStyle = s
            a.points = [CGPoint(x: 10, y: 100), CGPoint(x: 120, y: 140)]
            doc.push(.add(a))
        }
        XCTAssertNotNil(CaptureRenderer.render(source: doc.source, scale: 2, state: doc.state))
    }
}

final class ConfigTests: XCTestCase {
    func testParse() {
        var c = Config()
        let w = c.apply(ini: """
        # comment
        [output]
        autosave = false
        directory = /tmp/shots
        filename = shot-{date}
        [colors]
        palette = #ff0000, #00ff00, nope
        [background]
        default = aurora
        [hotkeys]
        capture = ctrl+alt+s
        """)
        XCTAssertTrue(w.isEmpty)
        XCTAssertFalse(c.autosave)
        XCTAssertEqual(c.directory.path, "/tmp/shots")
        XCTAssertEqual(c.palette.count, 2)
        XCTAssertEqual(c.defaultBackground, .aurora)
        XCTAssertEqual(c.hotkeys["capture"], "ctrl+alt+s")
        XCTAssertEqual(c.hotkeys["scroll"], "cmd+shift+1")
    }

    func testFilenameExpansion() {
        let d = DateComponents(calendar: Calendar.current, year: 2026, month: 8, day: 23, hour: 14, minute: 5, second: 9).date!
        XCTAssertEqual(Config.expand("screenshot-{date}_{time}-{app}", date: d, app: "Google Chrome"), "screenshot-2026-08-23_14-05-09-google-chrome")
        XCTAssertEqual(Config.expand("screenshot-{date}_{time}-{app}", date: d, app: nil), "screenshot-2026-08-23_14-05-09")
        XCTAssertEqual(Config.expand("{app}-{date}", date: d, app: ""), "2026-08-23")
    }
}

final class StitchTests: XCTestCase {
    func testVerticalStitchWithStickyHeader() {
        let page = fixtureImage(width: 120, height: 900, seed: 3)
        let header = fixtureImage(width: 120, height: 30, seed: 99)
        func frame(at y: Int) -> CGImage {
            let ctx = CaptureRenderer.makeContext(width: 120, height: 200)!
            ctx.draw(crop(page, y: y, height: 200), in: CGRect(x: 0, y: 0, width: 120, height: 200))
            ctx.draw(header, in: CGRect(x: 0, y: 170, width: 120, height: 30))
            return ctx.makeImage()!
        }
        let s = Stitcher()
        XCTAssertEqual(s.add(frame(at: 0)), .first)
        XCTAssertEqual(s.add(frame(at: 0)), .unchanged)
        XCTAssertEqual(s.add(frame(at: 90)), .moved(90))
        XCTAssertEqual(s.add(frame(at: 200)), .moved(110))
        XCTAssertEqual(s.add(frame(at: 333)), .moved(133))
        let out = s.compose()!
        XCTAssertEqual(out.height, 333 + 200)
        // Below the header, output row r is page row r.
        for r in [40, 150, 260, 400, 500] {
            XCTAssertEqual(pixel(out, 60, r), pixel(page, 60, r), "row \(r)")
        }
        XCTAssertEqual(pixel(out, 60, 10), pixel(header, 60, 10))
    }

    func testHorizontal() {
        let page = fixtureImage(width: 120, height: 600, seed: 5)
        // Rotate semantics: build wide frames by taking columns from a rotated page.
        let ctxW = CaptureRenderer.makeContext(width: 600, height: 120)!
        ctxW.translateBy(x: 0, y: 120)
        ctxW.rotate(by: -.pi / 2)
        ctxW.draw(page, in: CGRect(x: 0, y: 0, width: 120, height: 600))
        let wide = ctxW.makeImage()!
        let s = Stitcher(axis: .horizontal)
        s.add(wide.cropping(to: CGRect(x: 0, y: 0, width: 200, height: 120))!)
        XCTAssertEqual(s.add(wide.cropping(to: CGRect(x: 70, y: 0, width: 200, height: 120))!), .moved(70))
        let out = s.compose()!
        XCTAssertEqual(out.width, 270)
        XCTAssertEqual(pixel(out, 230, 50), pixel(wide, 230, 50))
    }
}

final class RecentTests: XCTestCase {
    func testRoundTripAndPrune() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macsnap-recent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecentStore(root: root, limit: 2)
        var doc = SnapDocument(source: fixtureImage(width: 64, height: 64), scale: 2)
        var a = Annotation(id: 1, kind: .rect)
        a.rect = CGRect(x: 1, y: 1, width: 5, height: 5)
        doc.push(.add(a))
        for i in 0..<3 {
            try store.save(id: "e\(i)", document: doc, thumbnail: nil, meta: .init(app: nil, savedPath: nil, date: Date()))
            Thread.sleep(forTimeInterval: 0.02)
        }
        let list = store.list()
        XCTAssertEqual(list.map(\.id), ["e2", "e1"])
        let back = try store.load(list[0])
        XCTAssertEqual(back.state, doc.state)
        XCTAssertEqual(back.scale, 2)
    }
}
