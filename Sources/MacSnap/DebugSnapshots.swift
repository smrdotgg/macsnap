import AppKit
import MacSnapCore

/// Hidden developer mode (MACSNAP_UI_SNAPSHOT=<dir> [MACSNAP_UI_FIXTURE=<png>]):
/// renders the real views offscreen and drives them with synthesized events,
/// so UI changes can be checked without screen-recording permission.
@MainActor
enum DebugSnapshots {
    static func run(dir: URL, fixture: URL?) {
        if let fonts = Bundle.main.resourceURL?.appendingPathComponent("Fonts"), FileManager.default.fileExists(atPath: fonts.path) {
            TextLayout.register(fontsIn: fonts)
        } else {
            TextLayout.register(fontsIn: URL(fileURLWithPath: "Resources/Fonts"))
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = CGSize(width: 1280, height: 800)
        let image: CGImage = {
            if let fixture, let l = ImageFiles.load(url: fixture) {
                let ctx = CaptureRenderer.makeContext(width: Int(size.width * 2), height: Int(size.height * 2))!
                ctx.interpolationQuality = .high
                ctx.draw(l.image, in: CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2))
                return ctx.makeImage()!
            }
            let ctx = CaptureRenderer.makeContext(width: Int(size.width * 2), height: Int(size.height * 2))!
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.25, blue: 0.35, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2))
            return ctx.makeImage()!
        }()
        let windows = [
            WindowInfo(frame: CGRect(x: 270, y: 16, width: 660, height: 650), app: "Google Chrome", title: "X", windowID: 1),
        ]
        let snap = ScreenSnapshot(image: image, scale: 2, screen: screen, displayID: 1, windows: windows)

        // 1. Capture overlay: idle crosshair over a window, then a region drag.
        let recentImg = NSImage(cgImage: image, size: size)
        let ov = CaptureOverlayView(frame: CGRect(origin: .zero, size: size), snap: snap, mode: .smart, annotate: false,
                                    recents: [RecentCard(entry: .init(id: "a", directory: dir, date: Date()), image: recentImg),
                                              RecentCard(entry: .init(id: "b", directory: dir, date: Date()), image: recentImg)])
        send(.mouseMoved, to: ov, at: CGPoint(x: 600, y: 300))
        save(ov, dir, "1-overlay-hover-window")
        send(.leftMouseDown, to: ov, at: CGPoint(x: 450, y: 250))
        send(.leftMouseDragged, to: ov, at: CGPoint(x: 820, y: 470))
        save(ov, dir, "2-overlay-drag-region")
        send(.leftMouseUp, to: ov, at: CGPoint(x: 820, y: 470))
        send(.mouseMoved, to: ov, at: CGPoint(x: 1240, y: 400))
        save(ov, dir, "3-overlay-recents-fanned")

        // 2. Editor, overlay presentation, with a few layers drawn through events.
        let doc = SnapDocument(source: image, scale: 2, crop: CGRect(x: 450, y: 250, width: 370, height: 220))
        let settings = ToolSettings(color: RGBA.defaultPalette[0], palette: RGBA.defaultPalette, customColor: RGBA.defaultPalette[0])
        let ed = EditorView(frame: CGRect(origin: .zero, size: size), document: doc, settings: settings, overlay: true, customBackground: nil)
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        win.contentView = ed
        ed.place(native: true)
        key(ed, "a")
        drag(ed, from: CGPoint(x: 480, y: 300), to: CGPoint(x: 640, y: 360))
        key(ed, "r")
        drag(ed, from: CGPoint(x: 660, y: 280), to: CGPoint(x: 800, y: 340))
        key(ed, "c")
        click(ed, at: CGPoint(x: 500, y: 430))
        click(ed, at: CGPoint(x: 540, y: 430))
        key(ed, "t")
        click(ed, at: CGPoint(x: 600, y: 400))
        ed.insertTextForDebug("Ship it!")
        save(ed, dir, "4-editor-typing")
        key(ed, "\r")
        // Arrow past the right edge grows the canvas (framed).
        key(ed, "a")
        key(ed, "a") // pointy
        drag(ed, from: CGPoint(x: 900, y: 420), to: CGPoint(x: 760, y: 330))
        key(ed, "v")
        click(ed, at: CGPoint(x: 700, y: 281))
        save(ed, dir, "5-editor-layers-selected")
        key(ed, "b")
        key(ed, "b")
        save(ed, dir, "6-editor-backdrop")
        // Undo everything back and redo.
        let n = ed.document.ops.count
        for _ in 0..<n { ed.undo() }
        save(ed, dir, "7-editor-undone")
        for _ in 0..<n { ed.redo() }

        // 3. Cut tool preview and result.
        key(ed, "x")
        send(.leftMouseDown, to: ed, at: CGPoint(x: 600, y: 370))
        send(.leftMouseDragged, to: ed, at: CGPoint(x: 602, y: 400))
        save(ed, dir, "8-editor-cut-preview")
        send(.leftMouseUp, to: ed, at: CGPoint(x: 602, y: 400))
        save(ed, dir, "9-editor-after-cut")

        // 4. Window presentation.
        let ed2 = EditorView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700), document: ed.document, settings: settings, overlay: false, customBackground: nil)
        let win2 = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: true)
        win2.contentView = ed2
        ed2.place(native: false)
        save(ed2, dir, "10-editor-window")

        // 5. Preview card, idle tilted and hovered.
        let shot = Shot(document: ed.document, app: "Chrome")
        shot.flat = CaptureRenderer.render(source: CaptureRenderer.composeCuts(doc.source, scale: 2, cuts: ed.document.state.cuts), scale: 2, state: ed.document.state)
        let card = PreviewCard(shot: shot, screen: screen, pinned: false)
        card.tilt = -3
        save(card.view, dir, "11-preview-idle")
        card.tilt = 0
        card.view.mouseEntered(with: NSEvent())
        save(card.view, dir, "12-preview-hover")
        for v in card.view.subviews { print("control", type(of: v), v.frame, v.isHidden) }

        // 6. Export.
        if let flat = shot.flat { try? ImageFiles.writePNG(flat, scale: 2, to: dir.appendingPathComponent("13-export.png")) }
        // 7. Welcome window, before and after permission.
        if NSApp.applicationIconImage?.name() == NSImage.applicationIconName || Bundle.main.bundleURL.pathExtension != "app",
           let icon = NSImage(contentsOf: URL(fileURLWithPath: "Resources/AppIcon.icns")) {
            NSApp.applicationIconImage = icon
        }
        for (granted, look) in [(false, NSAppearance.Name.aqua), (true, .darkAqua)] {
            let w = WelcomeView(hotkeys: ["capture": "cmd+shift+2", "scroll": "cmd+shift+1"])
            w.permissionOverride = granted
            w.refresh()
            let backed = Backed(frame: CGRect(origin: .zero, size: w.fittingSize))
            w.frame = backed.bounds
            backed.addSubview(w)
            let win = NSWindow(contentRect: backed.frame, styleMask: [.titled], backing: .buffered, defer: true)
            win.appearance = NSAppearance(named: look)
            win.contentView = backed
            win.layoutIfNeeded()
            save(backed, dir, granted ? "15-welcome-granted-dark" : "14-welcome")
        }
        // 8. OCR through the app's own code path (with its model fallback).
        final class Box: @unchecked Sendable { var lines: Int?; var error: String?; var done = false }
        let box = Box()
        let ocrImage = image
        Task.detached {
            do { box.lines = try await OCR.recognize(ocrImage).count } catch { box.error = "\(error)" }
            box.done = true
        }
        while !box.done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        print("OCR:", box.lines.map { "\($0) lines" } ?? "failed \(box.error ?? "")")
        _ = (win, win2)
        print("snapshots written to \(dir.path)")
    }

    static func save(_ view: NSView, _ dir: URL, _ name: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
    }

    static func send(_ type: NSEvent.EventType, to view: NSView, at p: CGPoint, flags: NSEvent.ModifierFlags = []) {
        let winPoint = view.convert(p, to: nil)
        guard let e = NSEvent.mouseEvent(with: type, location: winPoint, modifierFlags: flags, timestamp: 0,
                                         windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                         clickCount: 1, pressure: 1) else { return }
        switch type {
        case .mouseMoved: view.mouseMoved(with: e)
        case .leftMouseDown: view.mouseDown(with: e)
        case .leftMouseDragged: view.mouseDragged(with: e)
        case .leftMouseUp: view.mouseUp(with: e)
        default: break
        }
    }

    static func drag(_ v: NSView, from a: CGPoint, to b: CGPoint) {
        send(.leftMouseDown, to: v, at: a)
        for i in 1...8 {
            let t = CGFloat(i) / 8
            send(.leftMouseDragged, to: v, at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        send(.leftMouseUp, to: v, at: b)
    }

    static func click(_ v: NSView, at p: CGPoint) {
        send(.leftMouseDown, to: v, at: p)
        send(.leftMouseUp, to: v, at: p)
    }

    static func key(_ v: NSView, _ chars: String, flags: NSEvent.ModifierFlags = []) {
        let code: UInt16 = chars == "\r" ? 36 : 0
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                       context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
        if let tv = v.window?.firstResponder as? NSTextView, chars == "\r" {
            tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            return
        }
        v.keyDown(with: e)
    }
}

/// Paints the window background so offscreen captures of controls are legible.
private final class Backed: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}

extension EditorView {
    func insertTextForDebug(_ s: String) {
        guard let tv = window?.firstResponder as? NSTextView else { return }
        tv.insertText(s, replacementRange: tv.selectedRange())
    }
}
