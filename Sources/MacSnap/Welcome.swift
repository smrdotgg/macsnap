import AppKit
import ServiceManagement

/// First-run setup: explains the menu bar icon and hotkeys, and walks
/// through Screen Recording permission, which only takes effect after a
/// relaunch. Shown on first launch, whenever a capture finds the permission
/// missing, and from the menu bar.
@MainActor
final class WelcomeWindow: NSObject, NSWindowDelegate {
    static let seenKey = "welcomeSeen"
    private static var current: WelcomeWindow?

    private let window: NSWindow
    private let content: WelcomeView
    private var timer: Timer?

    static func show() {
        if current == nil { current = WelcomeWindow() }
        current?.present()
    }

    private override init() {
        content = WelcomeView(hotkeys: AppController.shared.config.hotkeys)
        window = NSWindow(contentRect: CGRect(origin: .zero, size: content.fittingSize),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.delegate = self
        window.center()
        content.onDone = { [weak self] in self?.window.close() }
    }

    private func present() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        content.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // The permission state can change while the window is open.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { WelcomeWindow.current?.content.refresh() }
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            timer?.invalidate()
            WelcomeWindow.current = nil
        }
    }

    /// Quits and reopens the app once this process has exited, so the new
    /// instance can register the same hotkeys.
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// The welcome window's content, also rendered by the UI snapshot mode.
@MainActor
final class WelcomeView: NSView {
    var onDone: () -> Void = {}
    private let permissionStatus = NSTextField(labelWithString: "")
    private let permissionButton = NSButton()
    private let relaunchButton = NSButton()
    private let relaunchNote = NSTextField(wrappingLabelWithString: "")
    private let loginCheckbox = NSButton(checkboxWithTitle: "Open MacSnap when you log in", target: nil, action: nil)
    private let stack = NSStackView()
    /// Snapshot mode can force the permission state it shows.
    var permissionOverride: Bool?

    init(hotkeys: [String: String]) {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let title = NSTextField(labelWithString: "Welcome to MacSnap")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let intro = Self.paragraph(width: 348, "MacSnap lives in the menu bar, under the camera icon. Press a hotkey, then drag an area, click a window, or click open space for the whole screen. The capture is copied, saved to your Screenshots folder, and shown as a preview you can edit.")

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 32, bottom: 24, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 500),
        ])

        let header = NSStackView(views: [icon, NSStackView.vertical([title, intro], spacing: 6)])
        header.alignment = .centerY
        header.spacing = 16
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(hotkeyList(hotkeys))
        stack.setCustomSpacing(22, after: stack.arrangedSubviews.last!)

        // Step: Screen Recording.
        stack.addArrangedSubview(Self.heading("Screen Recording permission"))
        stack.addArrangedSubview(Self.paragraph(width: 436, "macOS asks before any app can see the screen. MacSnap only reads it when you press a capture hotkey, and nothing leaves your Mac."))
        permissionButton.bezelStyle = .push
        permissionButton.target = self
        permissionButton.action = #selector(requestPermission)
        relaunchButton.title = "Quit & Reopen MacSnap"
        relaunchButton.bezelStyle = .push
        relaunchButton.target = self
        relaunchButton.action = #selector(relaunch)
        let permRow = NSStackView(views: [permissionStatus, permissionButton, relaunchButton])
        permRow.spacing = 10
        permRow.alignment = .centerY
        stack.addArrangedSubview(permRow)
        relaunchNote.font = .systemFont(ofSize: 11)
        relaunchNote.textColor = .secondaryLabelColor
        relaunchNote.stringValue = "After you switch MacSnap on in System Settings, quit and reopen it so the permission takes effect."
        relaunchNote.preferredMaxLayoutWidth = 436
        relaunchNote.widthAnchor.constraint(equalToConstant: 436).isActive = true
        stack.addArrangedSubview(relaunchNote)
        stack.setCustomSpacing(22, after: relaunchNote)

        // Step: login item.
        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLogin)
        stack.addArrangedSubview(loginCheckbox)
        let note = Self.paragraph(width: 436, "Scroll capture's auto-scroll also needs Accessibility permission; macOS asks the first time you use it. Change hotkeys and other settings with Edit Configuration… in the menu bar.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)

        let config = NSButton(title: "Edit Configuration…", target: self, action: #selector(editConfig))
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [config, spacer, done])
        footer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let granted = permissionOverride ?? ScreenCapture.hasPermission
        permissionStatus.stringValue = granted ? "✓ Allowed" : "Not allowed yet"
        permissionStatus.textColor = granted ? .systemGreen : .secondaryLabelColor
        permissionStatus.font = .systemFont(ofSize: 13, weight: .medium)
        permissionButton.title = "Open System Settings…"
        permissionButton.isHidden = granted
        relaunchButton.isHidden = granted
        relaunchNote.isHidden = granted
        loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func hotkeyList(_ hotkeys: [String: String]) -> NSView {
        let names: [(String, String)] = [("capture", "Capture"), ("annotate", "Capture and annotate"), ("scroll", "Scroll capture"),
                                         ("region", "Capture an area"), ("window", "Capture a window"),
                                         ("fullscreen", "Capture the screen"), ("clipboard", "Annotate the clipboard image")]
        let grid = NSGridView()
        grid.rowSpacing = 6
        grid.columnSpacing = 14
        for (key, label) in names {
            guard let combo = hotkeys[key].flatMap(HotKeys.parse) else { continue }
            let keys = NSTextField(labelWithString: combo.display)
            keys.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            grid.addRow(with: [keys, NSTextField(labelWithString: label)])
        }
        if grid.numberOfRows == 0 {
            grid.addRow(with: [NSTextField(labelWithString: "No hotkeys are set. Use the menu bar icon, or add some in the configuration.")])
        }
        return grid
    }

    private static func heading(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 14, weight: .semibold)
        return t
    }

    private static func paragraph(width: CGFloat, _ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: 13)
        t.isSelectable = false
        t.preferredMaxLayoutWidth = width
        t.widthAnchor.constraint(equalToConstant: width).isActive = true
        return t
    }

    @objc private func requestPermission() {
        // The first request registers MacSnap in the list (and shows the
        // system prompt); later ones do nothing, so always open the pane too.
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func relaunch() { WelcomeWindow.relaunch() }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            DevLog.write("launch at login failed: \(error)")
        }
        refresh()
    }

    @objc private func editConfig() { AppController.shared.editConfig() }
    @objc private func done() { onDone() }
}

private extension NSStackView {
    static func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }
}
