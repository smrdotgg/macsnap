import AppKit
import MacSnapCore
import UniformTypeIdentifiers

/// A completed or in-progress capture: its editable document and outputs.
final class Shot {
    let id: String
    var document: SnapDocument
    var app: String?
    var savedURL: URL?
    var flat: CGImage?
    /// Logical scale of `flat`.
    var scale: CGFloat { document.scale }
    /// The display it was captured on (for scroll capture from the editor).
    var screen: NSScreen?

    init(id: String = UUID().uuidString, document: SnapDocument, app: String?) {
        self.id = id
        self.document = document
        self.app = app
    }
}

enum EditorAction {
    case copy, save, saveAs, copyAndSave, pin, dismiss
}

@MainActor
final class EditorController: NSObject, NSWindowDelegate {
    let shot: Shot
    weak var originCard: PreviewCard?
    let screen: NSScreen
    private(set) var presentation: Config.EditorMode
    private(set) var window: NSWindow!
    private(set) var view: EditorView!
    private let native: Bool
    private var settings: ToolSettings
    private let customBackground: CGImage?
    var onAction: ((EditorController, EditorAction, URL?) -> Void)?
    var onSettings: ((ToolSettings) -> Void)?
    var onChange: ((EditorController) -> Void)?
    var onScrollCapture: ((EditorController) -> Void)?
    var onPresentationChange: (() -> Void)?
    private var finished = false
    private var changeWork: DispatchWorkItem?
    private var savePanel: NSSavePanel?

    init(shot: Shot, screen: NSScreen, presentation: Config.EditorMode, native: Bool, settings: ToolSettings, customBackground: CGImage?) {
        self.shot = shot
        self.screen = screen
        self.presentation = presentation
        self.native = native
        self.settings = settings
        self.customBackground = customBackground
        super.init()
    }

    var canScrollCapture: Bool {
        native && presentation == .overlay && shot.document.state.cuts.isEmpty && shot.screen != nil
    }

    func show() {
        buildWindow(document: shot.document, placeNative: native && presentation == .overlay)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    private func buildWindow(document: SnapDocument, placeNative: Bool) {
        let overlay = presentation == .overlay
        if overlay {
            let panel = KeyPanel(frame: screen.frame, level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1))
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
            window = panel
        } else {
            let lay = CaptureRenderer.layout(document.state)
            let vis = screen.visibleFrame
            let w = min(vis.width * 0.9, max(860, lay.size.width + 80))
            let h = min(vis.height * 0.9, max(540, lay.size.height + 140))
            let rect = CGRect(x: vis.midX - w / 2, y: vis.midY - h / 2, width: w, height: h)
            let win = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
            win.titlebarAppearsTransparent = true
            win.title = "MacSnap" + (shot.app.map { " — \($0)" } ?? "")
            win.isReleasedWhenClosed = false
            win.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)
            win.appearance = NSAppearance(named: .darkAqua)
            win.minSize = CGSize(width: 640, height: 400)
            win.setFrame(win.frameRect(forContentRect: rect), display: false)
            window = win
        }
        window.delegate = self
        let content = window.contentView!.bounds
        view = EditorView(frame: content, document: document, settings: settings, overlay: overlay, customBackground: customBackground)
        view.autoresizingMask = [.width, .height]
        view.controller = self
        window.contentView = view
        view.place(native: placeNative)
    }

    func togglePresentation() {
        let doc = view.document
        settings = view.settings
        NSColorPanel.shared.orderOut(nil) // it targets the view being replaced
        let old = window!
        presentation = presentation == .overlay ? .window : .overlay
        buildWindow(document: doc, placeNative: false)
        onPresentationChange?()
        old.delegate = nil
        old.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    func perform(_ action: EditorAction) {
        guard !finished, savePanel == nil else { return }
        if action == .saveAs {
            runSaveAs()
            return
        }
        view.commitText(dismissAfter: false)
        finished = true
        onAction?(self, action, nil)
    }

    private func runSaveAs() {
        view.commitText(dismissAfter: false)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let cfg = AppController.shared.config
        panel.directoryURL = cfg.directory
        panel.nameFieldStringValue = cfg.outputURL(app: shot.app).lastPathComponent
        panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        savePanel = panel
        panel.begin { [weak self] resp in
            self?.savePanel = nil
            guard let self, resp == .OK, var url = panel.url else { return }
            if url.pathExtension.isEmpty { url.appendPathExtension("png") }
            guard url.pathExtension.lowercased() == "png" else {
                self.view.flash("Only PNG is supported")
                return
            }
            self.finished = true
            self.onAction?(self, .saveAs, url)
        }
    }

    /// Re-enables actions after a failed output.
    func reopen(error: String) {
        finished = false
        view.flash(error, seconds: 4)
    }

    func close() {
        finished = true
        savePanel?.cancel(nil)
        savePanel = nil
        window.delegate = nil
        window.orderOut(nil)
        NSColorPanel.shared.orderOut(nil)
    }

    /// Commits any label being typed; for outputs.
    var currentDocument: SnapDocument { view.document }
    /// Leaves a label being typed alone; for autosave.
    var committedDocument: SnapDocument { view.committedDocument }

    func documentChanged() {
        changeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onChange?(self)
        }
        changeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    func rememberSettings(_ s: ToolSettings) {
        settings = s
        onSettings?(s)
    }

    func startScrollCapture() {
        guard canScrollCapture else { return }
        finished = true
        onScrollCapture?(self)
    }

    var cropOnScreen: CGRect { view.document.state.crop }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        perform(.dismiss)
        return false
    }
}
