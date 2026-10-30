import AppKit
import ApplicationServices
import MacSnapCore

/// Draws the live region's frame without taking any input.
final class RegionFrameView: NSView {
    var region: CGRect = .zero
    var active = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = region.insetBy(dx: -2, dy: -2)
        let path = NSBezierPath(rect: r)
        path.lineWidth = 3
        (active ? NSColor.systemRed : Chrome.accent).setStroke()
        path.stroke()
    }
}

/// A region on screen that the user (or MacSnap) scrolls while frames are
/// captured and stitched.
@MainActor
final class ScrollCaptureSession: NSObject {
    let screen: NSScreen
    /// Screen-local, top-left origin points.
    let region: CGRect
    let annotate: Bool
    private let frameWindow: NSPanel
    private let frameView: RegionFrameView
    private let controls: ScrollControlPanel
    private var grabber: ScreenCapture.RegionGrabber?
    private var stitcher: Stitcher?
    private var timer: Timer?
    private var inFlight = false
    private var autoTask: Task<Void, Never>?
    private var finished = false
    var onFinish: ((ScrollCaptureSession, CGImage?, CGFloat) -> Void)?

    init(screen: NSScreen, region: CGRect, annotate: Bool) {
        self.screen = screen
        self.region = region
        self.annotate = annotate
        frameWindow = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        frameWindow.level = .statusBar
        frameWindow.isOpaque = false
        frameWindow.backgroundColor = .clear
        frameWindow.ignoresMouseEvents = true
        frameWindow.hasShadow = false
        frameWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        frameView = RegionFrameView(frame: CGRect(origin: .zero, size: screen.frame.size))
        frameView.region = region
        frameWindow.contentView = frameView
        controls = ScrollControlPanel()
        super.init()
        controls.session = self
    }

    func start() {
        frameWindow.setFrame(screen.frame, display: false)
        frameWindow.orderFrontRegardless()
        positionControls()
        controls.panel.makeKeyAndOrderFront(nil)
        controls.setStatus("Pick a direction, then scroll the page")
        Task {
            do {
                grabber = try await ScreenCapture.RegionGrabber(screen: screen, rect: region)
            } catch {
                controls.setStatus(error.localizedDescription)
            }
        }
    }

    private func positionControls() {
        let size = controls.panel.frame.size
        let regionCocoa = ScreenCapture.cocoaRect(local: region, on: screen)
        let vis = screen.visibleFrame
        var origin = CGPoint(x: regionCocoa.midX - size.width / 2, y: regionCocoa.minY - size.height - 14)
        if origin.y < vis.minY + 8 { origin.y = regionCocoa.maxY + 14 }
        if origin.y + size.height > vis.maxY - 8 { origin.y = regionCocoa.minY + 14 }
        origin.x = min(max(vis.minX + 8, origin.x), vis.maxX - size.width - 8)
        controls.panel.setFrameOrigin(origin)
    }

    func begin(axis: Stitcher.Axis, auto: Bool) {
        guard grabber != nil, stitcher == nil else { return }
        let s = Stitcher(axis: axis)
        stitcher = s
        frameView.active = true
        controls.setRunning(true)
        if auto {
            guard ensureAccessibility() else {
                stitcher = nil
                frameView.active = false
                controls.setRunning(false)
                return
            }
            autoTask = Task { await runAuto(axis: axis) }
        } else {
            controls.setStatus("Scroll the page now · Return when done")
            Task { await grabOnce() }
            timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.grabOnce() }
                }
            }
        }
    }

    @discardableResult
    private func grabOnce() async -> Stitcher.Outcome? {
        guard !inFlight, let grabber, let stitcher, !finished else { return nil }
        inFlight = true
        defer { inFlight = false }
        guard let img = try? await grabber.grab() else { return nil }
        let outcome = stitcher.add(img)
        controls.setStatus("\(stitcher.frameCount) frames · \(stitcher.stitchedLength) px" + (outcome == .lost ? " · moved too fast, scroll slower" : ""))
        if stitcher.isFull { done() }
        return outcome
    }

    private func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        controls.setStatus("Auto-scroll needs Accessibility permission (System Settings › Privacy)")
        return false
    }

    private func runAuto(axis: Stitcher.Axis) async {
        let regionQ = ScreenCapture.quartzRect(ScreenCapture.cocoaRect(local: region, on: screen))
        let center = CGPoint(x: regionQ.midX, y: regionQ.midY)
        CGWarpMouseCursorPosition(center)
        controls.setStatus("Auto-scrolling · Return stops")
        await grabOnce()
        var still = 0
        let total = (axis == .vertical ? region.height : region.width) * 0.55
        while !finished, !Task.isCancelled {
            let steps = 6
            for _ in 0..<steps {
                let d = Int32(-(total / CGFloat(steps)).rounded())
                let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                 wheel1: axis == .vertical ? d : 0, wheel2: axis == .horizontal ? d : 0, wheel3: 0)
                ev?.location = center
                ev?.post(tap: .cghidEventTap)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            try? await Task.sleep(nanoseconds: 380_000_000)
            var outcome = await grabOnce()
            while outcome == nil, !finished {
                try? await Task.sleep(nanoseconds: 50_000_000)
                outcome = await grabOnce()
            }
            if outcome == .unchanged { still += 1 } else { still = 0 }
            if still >= 2 { break }
        }
        if !finished { done() }
    }

    func done() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        autoTask?.cancel()
        let image = stitcher?.compose()
        let scale = grabber?.scale ?? screen.backingScaleFactor
        teardown()
        onFinish?(self, image, scale)
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        autoTask?.cancel()
        teardown()
        onFinish?(self, nil, 1)
    }

    private func teardown() {
        frameWindow.orderOut(nil)
        controls.panel.orderOut(nil)
    }
}

@MainActor
final class ScrollControlPanel: NSObject {
    let panel: ControlKeyPanel
    private let bar: HUDBar
    private let status = NSTextField(labelWithString: "")
    private var directionButtons: [HUDButton] = []
    weak var session: ScrollCaptureSession? { didSet { panel.session = session } }

    override init() {
        bar = HUDBar(frame: .zero)
        panel = ControlKeyPanel(frame: CGRect(x: 0, y: 0, width: 10, height: 10), level: .statusBar)
        super.init()
        func button(_ title: String, _ symbol: String, _ tip: String, _ w: CGFloat, _ action: @escaping () -> Void) -> HUDButton {
            let b = HUDButton(symbol: symbol, tip: tip, size: CGSize(width: w, height: 30), action: action)
            b.label = title
            return b
        }
        directionButtons = [
            button("Scroll", "arrow.down", "Capture while you scroll down", 82) { [weak self] in self?.session?.begin(axis: .vertical, auto: false) },
            button("Scroll", "arrow.right", "Capture while you scroll right", 82) { [weak self] in self?.session?.begin(axis: .horizontal, auto: false) },
            button("Auto", "arrow.down.to.line", "MacSnap scrolls down until the page stops", 74) { [weak self] in self?.session?.begin(axis: .vertical, auto: true) },
            button("Auto", "arrow.right.to.line", "MacSnap scrolls right until the page stops", 74) { [weak self] in self?.session?.begin(axis: .horizontal, auto: true) },
        ]
        status.font = Chrome.mono(11)
        status.textColor = Chrome.dimText
        status.frame = CGRect(x: 0, y: 0, width: 250, height: 30)
        status.lineBreakMode = .byTruncatingTail
        let statusBox = NSView(frame: CGRect(x: 0, y: 0, width: 250, height: 30))
        status.frame = CGRect(x: 8, y: 7, width: 242, height: 16)
        statusBox.addSubview(status)
        let done = button("Done", "checkmark", "Stitch and finish · Return", 74) { [weak self] in self?.session?.done() }
        let cancel = HUDButton(symbol: "xmark", tip: "Cancel · Esc") { [weak self] in self?.session?.cancel() }
        bar.layoutRow(directionButtons + [HUDSeparator(), statusBox, HUDSeparator(), done, cancel])
        panel.setContentSize(bar.frame.size)
        panel.contentView = bar
    }

    func setStatus(_ s: String) { status.stringValue = s }

    func setRunning(_ running: Bool) {
        directionButtons.forEach { $0.enabled = !running }
    }
}

final class ControlKeyPanel: KeyPanel {
    weak var session: ScrollCaptureSession?

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53: MainActor.assumeIsolated { session?.cancel() }
        case 36, 76: MainActor.assumeIsolated { session?.done() }
        default: super.keyDown(with: e)
        }
    }
}
