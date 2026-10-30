import AppKit
import ScreenCaptureKit

/// A frozen frame of one display plus the windows on it, captured before any
/// MacSnap overlay is mapped.
struct ScreenSnapshot {
    var image: CGImage
    /// Pixels per point.
    var scale: CGFloat
    var screen: NSScreen
    var displayID: CGDirectDisplayID
    /// Windows front-to-back in screen-local, top-left-origin points.
    var windows: [WindowInfo]

    var size: CGSize { screen.frame.size }
}

struct WindowInfo {
    var frame: CGRect
    var app: String
    var title: String
    var windowID: CGWindowID
}

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case noDisplay
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "MacSnap needs Screen Recording permission."
        case .noDisplay: "The display under the pointer was not found."
        case .failed(let s): s
        }
    }
}

enum ScreenCapture {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    static func screenUnderPointer() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Cocoa global (bottom-left origin) → Quartz global (top-left origin).
    static func quartzRect(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? r.maxY
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    static func cocoaRect(fromQuartz r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? r.maxY
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// Converts a screen-local top-left rect to Cocoa global coordinates.
    static func cocoaRect(local r: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(x: screen.frame.minX + r.minX, y: screen.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    static func windows(on screen: NSScreen) -> [WindowInfo] {
        let screenQ = quartzRect(screen.frame)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = getpid()
        var out: [WindowInfo] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let b = w[kCGWindowBounds as String] as? [String: Double]
            else { continue }
            let frame = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard frame.width >= 40, frame.height >= 30, frame.intersects(screenQ) else { continue }
            let local = frame.offsetBy(dx: -screenQ.minX, dy: -screenQ.minY)
                .intersection(CGRect(origin: .zero, size: screenQ.size))
            out.append(WindowInfo(frame: local, app: w[kCGWindowOwnerName as String] as? String ?? "",
                                  title: w[kCGWindowName as String] as? String ?? "",
                                  windowID: w[kCGWindowNumber as String] as? CGWindowID ?? 0))
        }
        return out
    }

    private static func filter(for displayID: CGDirectDisplayID) async throws -> (SCContentFilter, SCDisplay) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if !hasPermission { throw ScreenCaptureError.permissionDenied }
            throw ScreenCaptureError.failed(error.localizedDescription)
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw ScreenCaptureError.noDisplay }
        // Our own previews, pins and overlays never appear in captures.
        let mine = content.applications.filter { $0.processID == getpid() }
        return (SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: []), display)
    }

    static func snapshot(of screen: NSScreen) async throws -> ScreenSnapshot {
        let id = displayID(of: screen)
        let windows = windows(on: screen)
        let (filter, display) = try await filter(for: id)
        let scale = CGFloat(filter.pointPixelScale)
        let cfg = SCStreamConfiguration()
        cfg.width = Int((CGFloat(display.width) * scale).rounded())
        cfg.height = Int((CGFloat(display.height) * scale).rounded())
        cfg.showsCursor = false
        cfg.captureResolution = .best
        cfg.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        return ScreenSnapshot(image: image, scale: scale, screen: screen, displayID: id, windows: windows)
    }

    /// Repeated captures of one region of a display (scroll capture).
    final class RegionGrabber {
        let filter: SCContentFilter
        let config: SCStreamConfiguration
        let scale: CGFloat

        init(screen: NSScreen, rect local: CGRect) async throws {
            let (f, _) = try await ScreenCapture.filter(for: ScreenCapture.displayID(of: screen))
            filter = f
            scale = CGFloat(f.pointPixelScale)
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = local
            cfg.width = Int((local.width * scale).rounded())
            cfg.height = Int((local.height * scale).rounded())
            cfg.showsCursor = false
            cfg.captureResolution = .best
            cfg.colorSpaceName = CGColorSpace.sRGB
            config = cfg
        }

        func grab() async throws -> CGImage {
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }
}
