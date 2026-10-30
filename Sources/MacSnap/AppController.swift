import AppKit
import MacSnapCore
import ServiceManagement

struct CaptureRequest {
    var mode: CaptureMode = .smart
    var annotate = false
    var editorMode: Config.EditorMode?
    var quickCopy = false
    var quickSave = false
    var quick: Bool { quickCopy || quickSave }
}

@MainActor
final class AppController: NSObject, NSMenuDelegate {
    static let shared = AppController()

    private(set) var config = Config()
    let recents = RecentStore()
    let previews = PreviewStack()
    private var statusItem: NSStatusItem?
    private var overlay: CaptureOverlay?
    private var capturing = false
    private var scrollSession: ScrollCaptureSession?
    private var editors: [EditorController] = []
    private var previousApp: NSRunningApplication?
    private var toolSettings: ToolSettings!
    private var customBackground: CGImage?
    private var configWatcher: DispatchSourceFileSystemObject?

    // MARK: Lifecycle

    func start() {
        if let fonts = Bundle.main.resourceURL?.appendingPathComponent("Fonts") {
            TextLayout.register(fontsIn: fonts)
        }
        reloadConfig()
        setupStatusItem()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppController.shared.previews.relayout(animated: false) }
        }
        cleanRuntimeDir()
    }

    func reloadConfig() {
        let (cfg, warnings) = Config.load()
        config = cfg
        for w in warnings { NSLog("MacSnap config: \(w)") }
        let saved = UserDefaults.standard.string(forKey: "color").flatMap { RGBA(hex: $0) }
        toolSettings = ToolSettings(color: saved ?? cfg.palette.first ?? RGBA.defaultPalette[0], palette: cfg.palette, customColor: cfg.customColor)
        customBackground = cfg.backgroundImage.flatMap { ImageFiles.load(url: $0)?.image }
        if customBackground == nil, config.defaultBackground == .custom { config.defaultBackground = .off }
        registerHotkeys()
        rebuildMenu()
    }

    private func registerHotkeys() {
        HotKeys.shared.unregisterAll()
        let actions: [String: CaptureRequest] = [
            "capture": CaptureRequest(mode: .smart),
            "scroll": CaptureRequest(mode: .scroll),
            "region": CaptureRequest(mode: .region),
            "window": CaptureRequest(mode: .window),
            "fullscreen": CaptureRequest(mode: .fullscreen),
            "annotate": CaptureRequest(mode: .smart, annotate: true),
        ]
        for (name, combo) in config.hotkeys where !combo.isEmpty {
            if name == "clipboard" {
                if let c = HotKeys.parse(combo) { HotKeys.shared.register(c) { AppController.shared.openClipboard(editorMode: nil) } }
                continue
            }
            guard let req = actions[name] else {
                NSLog("MacSnap: unknown hotkey action \(name)")
                continue
            }
            guard let c = HotKeys.parse(combo) else {
                NSLog("MacSnap: cannot parse hotkey \(combo)")
                continue
            }
            if !HotKeys.shared.register(c, action: { AppController.shared.capture(req) }) {
                NSLog("MacSnap: hotkey \(combo) is taken by another app")
            }
        }
    }

    private func cleanRuntimeDir() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: Output.runtimeDir, includingPropertiesForKeys: nil) else { return }
        items.forEach { try? fm.removeItem(at: $0) }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Chrome.symbol("camera.viewfinder", size: 15)
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "MacSnap"
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { fillMenu(menu) }
    }

    private func fillMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, hotkey: String? = nil, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            if let hk = hotkey.flatMap({ config.hotkeys[$0] }), let (k, m) = HotKeys.menuEquivalent(hk) {
                item.keyEquivalent = k
                item.keyEquivalentModifierMask = m
            }
            menu.addItem(item)
        }
        add("Capture", hotkey: "capture") { [weak self] in self?.capture(CaptureRequest(mode: .smart)) }
        add("Capture and Annotate", hotkey: "annotate") { [weak self] in self?.capture(CaptureRequest(mode: .smart, annotate: true)) }
        add("Scroll Capture", hotkey: "scroll") { [weak self] in self?.capture(CaptureRequest(mode: .scroll)) }
        add("Capture Window", hotkey: "window") { [weak self] in self?.capture(CaptureRequest(mode: .window)) }
        add("Capture Screen", hotkey: "fullscreen") { [weak self] in self?.capture(CaptureRequest(mode: .fullscreen)) }
        menu.addItem(.separator())
        add("Annotate Clipboard Image", hotkey: "clipboard") { [weak self] in self?.openClipboard(editorMode: nil) }
        add("Open Image…") { [weak self] in self?.chooseFile() }
        let recentItem = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for e in recents.list() {
            let df = DateFormatter()
            df.dateStyle = .none
            df.timeStyle = .short
            let app = recents.meta(e)?.app.map { " — \($0)" } ?? ""
            let i = ClosureMenuItem(title: df.string(from: e.date) + app) { [weak self] in self?.openRecent(e) }
            if let img = NSImage(contentsOf: e.thumbnailURL) {
                let h: CGFloat = 32
                img.size = CGSize(width: h * img.size.width / max(1, img.size.height), height: h)
                i.image = img
            }
            sub.addItem(i)
        }
        if sub.items.isEmpty { sub.addItem(NSMenuItem(title: "None yet", action: nil, keyEquivalent: "")) }
        recentItem.submenu = sub
        menu.addItem(recentItem)
        add("Open Screenshots Folder") { [weak self] in
            guard let self else { return }
            try? FileManager.default.createDirectory(at: self.config.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(self.config.directory)
        }
        menu.addItem(.separator())
        if !ScreenCapture.hasPermission {
            add("⚠︎ Grant Screen Recording Permission…") { [weak self] in self?.promptPermission() }
        }
        add("Edit Configuration…") { [weak self] in self?.editConfig() }
        add("Reload Configuration") { [weak self] in self?.reloadConfig() }
        let login = ClosureMenuItem(title: "Launch at Login") {
            let svc = SMAppService.mainApp
            do {
                if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
            } catch {
                NSLog("MacSnap: launch at login failed: \(error)")
            }
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let about = NSMenuItem(title: "MacSnap \(version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        add("Quit MacSnap") { NSApp.terminate(nil) }
        menu.items.last?.keyEquivalent = "q"
    }

    private func editConfig() {
        let url = Config.defaultPath
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Self.sampleConfig.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    static let sampleConfig = """
    # MacSnap configuration. Every key is optional; delete what you don't need.
    # Use "Reload Configuration" from the menu bar after editing.

    [hotkeys]
    # Combos: cmd, shift, alt (option), ctrl + a key (a–z, 0–9, f1–f19, space…).
    # Leave a value empty to disable. Available actions: capture, annotate,
    # scroll, region, window, fullscreen, clipboard.
    capture = cmd+shift+2
    scroll = cmd+shift+1
    # annotate = cmd+shift+3
    # clipboard = cmd+shift+v

    [editor]
    # overlay (default): the editor fills the screen; window: a normal window.
    # W switches a live editor between the two.
    mode = overlay

    [output]
    # Save fresh captures as well as copying them. Default: true.
    autosave = true
    directory = ~/Pictures/Screenshots
    # Tokens: {date} {time} {app}. ".png" is appended.
    filename = screenshot-{date}_{time}-{app}

    [preview]
    # Seconds an untouched preview stays on screen.
    seconds = 7

    [colors]
    palette = #ff375f, #ff9f0a, #ffd60a, #30d158, #0a84ff, #bf5af2, #000000, #ffffff
    custom = #ff375f

    [background]
    # image = ~/Pictures/backdrop.jpg
    # none, slate, aurora, sunset, lagoon, violet, custom, grayShadow, grayFlat
    default = none

    """

    // MARK: Permission

    func promptPermission() {
        CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "MacSnap needs Screen Recording permission"
        alert.informativeText = "Allow MacSnap in System Settings › Privacy & Security › Screen & System Audio Recording, then try again. You may need to quit and reopen MacSnap afterwards."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    // MARK: Focus

    private func rememberFrontApp() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != getpid() { previousApp = front }
    }

    private func restoreFocusIfIdle() {
        guard overlay == nil, editors.isEmpty, scrollSession == nil else { return }
        previousApp?.activate()
    }

    // MARK: Capture

    func capture(_ req: CaptureRequest) {
        // The same hotkey dismisses an open overlay.
        if let o = overlay {
            o.cancel()
            return
        }
        if let s = scrollSession {
            s.cancel()
            return
        }
        guard !capturing else { return }
        guard ScreenCapture.hasPermission else {
            promptPermission()
            return
        }
        rememberFrontApp()
        capturing = true
        let screen = ScreenCapture.screenUnderPointer()
        let recentCards = req.mode == .fullscreen || req.quick ? [] : loadRecentCards()
        Task {
            defer { capturing = false }
            let snap: ScreenSnapshot
            do {
                snap = try await ScreenCapture.snapshot(of: screen)
            } catch ScreenCaptureError.permissionDenied {
                promptPermission()
                return
            } catch {
                showError("Capture failed", error.localizedDescription)
                return
            }
            if req.mode == .fullscreen {
                completeSelection(CaptureSelection(rect: CGRect(origin: .zero, size: snap.size), app: nil), snap: snap, req: req, annotate: req.annotate || req.editorMode != nil)
                return
            }
            let o = CaptureOverlay(snap: snap, mode: req.mode, annotate: req.annotate || req.editorMode != nil, recents: recentCards) { [weak self] outcome in
                guard let self else { return }
                self.overlay = nil
                switch outcome {
                case .cancelled:
                    self.restoreFocusIfIdle()
                case .selected(let sel, let annotate):
                    self.completeSelection(sel, snap: snap, req: req, annotate: annotate)
                case .scroll(let rect, let annotate):
                    self.startScroll(screen: snap.screen, region: rect, annotate: annotate, req: req)
                case .recent(let entry):
                    self.openRecent(entry)
                }
            }
            overlay = o
            NSApp.activate(ignoringOtherApps: true)
            o.show()
        }
    }

    private func loadRecentCards() -> [RecentCard] {
        recents.list().prefix(5).compactMap { e in
            guard let img = NSImage(contentsOf: e.thumbnailURL) else { return nil }
            return RecentCard(entry: e, image: img)
        }
    }

    private func completeSelection(_ sel: CaptureSelection, snap: ScreenSnapshot, req: CaptureRequest, annotate: Bool) {
        let doc = SnapDocument(source: snap.image, scale: snap.scale, crop: sel.rect, background: config.defaultBackground)
        let shot = Shot(document: doc, app: sel.app)
        shot.screen = snap.screen
        if annotate && !req.quick {
            openEditor(shot, screen: snap.screen, native: true, mode: req.editorMode ?? config.editorMode)
        } else {
            deliverFresh(shot, screen: snap.screen, req: req)
        }
    }

    private func startScroll(screen: NSScreen, region: CGRect, annotate: Bool, req: CaptureRequest) {
        let s = ScrollCaptureSession(screen: screen, region: region, annotate: annotate)
        s.onFinish = { [weak self] _, image, scale in
            guard let self else { return }
            self.scrollSession = nil
            guard let image else {
                self.restoreFocusIfIdle()
                return
            }
            let doc = SnapDocument(source: image, scale: scale, background: self.config.defaultBackground)
            let shot = Shot(document: doc, app: nil)
            if annotate && !req.quick {
                self.openEditor(shot, screen: screen, native: false, mode: req.editorMode ?? self.config.editorMode)
            } else {
                self.deliverFresh(shot, screen: screen, req: req)
            }
        }
        scrollSession = s
        s.start()
    }

    /// Fresh capture without annotation: copy, autosave, preview.
    private func deliverFresh(_ shot: Shot, screen: NSScreen, req: CaptureRequest) {
        let doc = shot.document
        let custom = customBackground
        let copy = req.quick ? req.quickCopy : true
        let save = req.quick ? req.quickSave : config.autosave
        let url = save ? config.outputURL(app: shot.app) : nil
        Task.detached(priority: .userInitiated) {
            let composed = CaptureRenderer.composeCuts(doc.source, scale: doc.scale, cuts: doc.state.cuts)
            guard let flat = CaptureRenderer.render(source: composed, scale: doc.scale, state: doc.state, customBackground: custom),
                  let png = ImageFiles.pngData(flat, scale: doc.scale) else {
                await MainActor.run { AppController.shared.showError("Capture failed", "Could not render the image.") }
                return
            }
            var savedOK = false
            if let url {
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try png.write(to: url, options: .atomic)
                    savedOK = true
                } catch {
                    await MainActor.run { AppController.shared.showError("Save failed", error.localizedDescription) }
                }
            }
            let saved = savedOK
            await MainActor.run {
                let app = AppController.shared
                if copy { Output.copyPNG(png) }
                shot.flat = flat
                if saved { shot.savedURL = url }
                if !req.quick {
                    let card = PreviewCard(shot: shot, screen: screen, pinned: false)
                    app.previews.add(card)
                }
                app.restoreFocusIfIdle()
                app.persist(shot)
            }
        }
    }

    // MARK: Editor

    func openEditor(_ shot: Shot, screen: NSScreen, native: Bool, mode: Config.EditorMode, origin: PreviewCard? = nil) {
        if let existing = editors.first(where: { $0.shot.id == shot.id }) {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let ed = EditorController(shot: shot, screen: screen, presentation: mode, native: native, settings: toolSettings, customBackground: customBackground)
        ed.originCard = origin
        origin?.busy += 1
        ed.onAction = { [weak self] ed, action, url in self?.editorAction(ed, action, url) }
        ed.onSettings = { [weak self] s in
            self?.toolSettings = s
            UserDefaults.standard.set(s.color.hex, forKey: "color")
        }
        ed.onChange = { [weak self] ed in
            ed.shot.document = ed.currentDocument
            self?.persist(ed.shot, render: false)
        }
        ed.onScrollCapture = { [weak self] ed in
            guard let self, let screen = ed.shot.screen else { return }
            let crop = ed.currentDocument.state.crop
            self.closeEditor(ed)
            self.startScroll(screen: screen, region: crop, annotate: true, req: CaptureRequest())
        }
        editors.append(ed)
        ed.show()
    }

    private func closeEditor(_ ed: EditorController) {
        ed.close()
        ed.originCard?.busy -= 1
        editors.removeAll { $0 === ed }
        restoreFocusIfIdle()
    }

    private func editorAction(_ ed: EditorController, _ action: EditorAction, _ saveAsURL: URL?) {
        let shot = ed.shot
        shot.document = ed.currentDocument
        let doc = shot.document
        let custom = customBackground
        let origin = ed.originCard
        let screen = origin?.screen ?? ed.screen

        if action == .dismiss {
            closeEditor(ed)
            // Keep the originating preview/pin, updated with the edits.
            if let origin, !origin.closed {
                Task.detached {
                    let composed = CaptureRenderer.composeCuts(doc.source, scale: doc.scale, cuts: doc.state.cuts)
                    let flat = CaptureRenderer.render(source: composed, scale: doc.scale, state: doc.state, customBackground: custom)
                    await MainActor.run {
                        if let flat, flat !== shot.flat {
                            shot.flat = flat
                            // Edits invalidate a previously saved file for path/reveal.
                            if doc.ops.count > 0 { shot.savedURL = nil }
                            origin.refreshImage()
                        }
                        AppController.shared.persist(shot)
                    }
                }
            } else {
                persist(shot)
            }
            return
        }

        let copy = action == .copy || action == .copyAndSave
        let saveURL: URL? = switch action {
        case .save, .copyAndSave: config.outputURL(app: shot.app)
        case .saveAs: saveAsURL
        default: nil
        }
        Task.detached(priority: .userInitiated) {
            let composed = CaptureRenderer.composeCuts(doc.source, scale: doc.scale, cuts: doc.state.cuts)
            guard let flat = CaptureRenderer.render(source: composed, scale: doc.scale, state: doc.state, customBackground: custom),
                  let png = ImageFiles.pngData(flat, scale: doc.scale) else {
                await MainActor.run { ed.reopen(error: "Rendering failed") }
                return
            }
            var saveError: String?
            if let saveURL {
                do {
                    try FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try png.write(to: saveURL, options: .atomic)
                } catch {
                    saveError = error.localizedDescription
                }
            }
            let failure = saveError
            await MainActor.run {
                let app = AppController.shared
                if let saveError = failure {
                    ed.reopen(error: "Save failed: \(saveError)")
                    return
                }
                if copy { Output.copyPNG(png) }
                shot.flat = flat
                shot.savedURL = saveURL
                app.closeEditor(ed)
                let card = PreviewCard(shot: shot, screen: screen, pinned: action == .pin || origin?.pinned == true)
                app.previews.replace(origin, with: card)
                app.persist(shot)
            }
        }
    }

    func edit(card: PreviewCard) {
        rememberFrontApp()
        let shot = card.shot
        let screen = card.screen
        let native = shot.screen != nil && shot.document.logicalSize == screen.frame.size && shot.screen == screen
        openEditor(shot, screen: screen, native: native, mode: config.editorMode, origin: card)
    }

    func openRecent(_ entry: RecentStore.Entry) {
        rememberFrontApp()
        // A live preview of the same shot keeps its card as the origin.
        if let card = previews.card(for: entry.id) {
            edit(card: card)
            return
        }
        do {
            let doc = try recents.load(entry)
            let meta = recents.meta(entry)
            let shot = Shot(id: entry.id, document: doc, app: meta?.app)
            shot.savedURL = meta?.savedPath.map { URL(fileURLWithPath: $0) }
            let screen = ScreenCapture.screenUnderPointer()
            let native = doc.logicalSize == screen.frame.size
            if native { shot.screen = screen }
            openEditor(shot, screen: screen, native: native, mode: config.editorMode)
        } catch {
            showError("Could not open the recent capture", error.localizedDescription)
        }
    }

    func openFile(_ url: URL, editorMode: Config.EditorMode?) {
        rememberFrontApp()
        guard let loaded = ImageFiles.load(url: url) else {
            showError("Could not open image", url.path)
            return
        }
        let doc = SnapDocument(source: loaded.image, scale: loaded.scale)
        let shot = Shot(document: doc, app: nil)
        shot.savedURL = url
        openEditor(shot, screen: ScreenCapture.screenUnderPointer(), native: false, mode: editorMode ?? config.editorMode)
    }

    func openClipboard(editorMode: Config.EditorMode?) {
        rememberFrontApp()
        guard let loaded = Output.clipboardImage() else {
            showError("No image on the clipboard", "Copy an image first, then try again.")
            return
        }
        let doc = SnapDocument(source: loaded.image, scale: loaded.scale)
        openEditor(Shot(document: doc, app: nil), screen: ScreenCapture.screenUnderPointer(), native: false, mode: editorMode ?? config.editorMode)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { openFile(url, editorMode: nil) }
    }

    // MARK: Recents

    /// Keeps the shot on the recents shelf (source + log + thumbnail), off the main thread.
    func persist(_ shot: Shot, render: Bool = true) {
        let doc = shot.document
        let flat = shot.flat
        let meta = RecentStore.Meta(app: shot.app, savedPath: shot.savedURL?.path, date: Date())
        let store = recents
        let id = shot.id
        let custom = customBackground
        DispatchQueue.global(qos: .utility).async {
            var image = flat
            if image == nil || !render {
                let composed = CaptureRenderer.composeCuts(doc.source, scale: doc.scale, cuts: doc.state.cuts)
                image = CaptureRenderer.render(source: composed, scale: doc.scale, state: doc.state, customBackground: custom)
            }
            let thumb = image.flatMap { ImageFiles.thumbnail($0, maxPixel: 480) }
            do {
                try store.save(id: id, document: doc, thumbnail: thumb, meta: meta)
            } catch {
                NSLog("MacSnap: could not keep recent capture: \(error)")
            }
        }
    }

    // MARK: Errors

    func showError(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
