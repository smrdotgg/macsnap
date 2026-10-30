// Renders the MacSnap app icon into an .iconset directory.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let r = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    NSGraphicsContext.current?.cgContext.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor(white: 0, alpha: 0.35).cgColor)
    NSGradient(colors: [NSColor(srgbRed: 0.55, green: 0.36, blue: 0.96, alpha: 1), NSColor(srgbRed: 0.93, green: 0.29, blue: 0.6, alpha: 1)])!
        .draw(in: path, angle: -60)
    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
    // A selection frame with corner handles.
    let f = r.insetBy(dx: r.width * 0.2, dy: r.width * 0.24)
    let frame = NSBezierPath(roundedRect: f, xRadius: s * 0.025, yRadius: s * 0.025)
    frame.lineWidth = s * 0.035
    NSColor.white.setStroke()
    let dash: [CGFloat] = [s * 0.05, s * 0.035]
    frame.setLineDash(dash, count: 2, phase: 0)
    frame.stroke()
    NSColor.white.setFill()
    for p in [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY), CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.maxX, y: f.maxY)] {
        let h = s * 0.075
        NSBezierPath(roundedRect: CGRect(x: p.x - h / 2, y: p.y - h / 2, width: h, height: h), xRadius: s * 0.015, yRadius: s * 0.015).fill()
    }
    // An arrow pointing into the frame.
    let a = NSBezierPath()
    a.move(to: CGPoint(x: f.minX + f.width * 0.28, y: f.minY + f.height * 0.28))
    a.line(to: CGPoint(x: f.maxX - f.width * 0.25, y: f.maxY - f.height * 0.3))
    a.lineWidth = s * 0.05
    a.lineCapStyle = .round
    NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1).setStroke()
    a.stroke()
    let tip = CGPoint(x: f.maxX - f.width * 0.2, y: f.maxY - f.height * 0.24)
    let head = NSBezierPath()
    head.move(to: tip)
    head.line(to: CGPoint(x: tip.x - s * 0.13, y: tip.y - s * 0.02))
    head.line(to: CGPoint(x: tip.x - s * 0.02, y: tip.y - s * 0.13))
    head.close()
    NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1).setFill()
    head.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
