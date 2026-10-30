import AppKit
import MacSnapCore

let bundleId = "dev.smr.macsnap"
let commandNotification = Notification.Name("dev.smr.macsnap.command")
let launchedMarker = "--launched-by-macsnap"

let usage = """
usage: macsnap [mode] [options] [image]

Modes (default: smart):
  smart                     Drag an area, click a window, or click open space
  region | --capture-region
  window | windows | --capture-window
  fullscreen | --capture-fullscreen
  scroll | --scroll         Stitch a scrolling area into one tall image

Options:
  --editor overlay|window   Annotate before any output
  --copy                    Copy only (no preview, no editor)
  --save                    Save only (combine with --copy for both)
  --file PATH | PATH        Open an image in the editor
  --clipboard               Open the clipboard image in the editor
  --help, --version
"""

enum Command {
    case idle
    case capture(CaptureRequest)
    case file(URL, Config.EditorMode?)
    case clipboard(Config.EditorMode?)
}

struct UsageError: Error { var message: String }

func parse(_ args: [String], cwd: String) throws -> Command {
    var req = CaptureRequest()
    var file: URL?
    var clipboard = false
    var sawMode = false
    var i = 0
    func setMode(_ m: CaptureMode) throws {
        if sawMode { throw UsageError(message: "only one capture mode may be given") }
        sawMode = true
        req.mode = m
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "smart", "capture": try setMode(.smart)
        case "region", "--capture-region": try setMode(.region)
        case "window", "windows", "--capture-window": try setMode(.window)
        case "fullscreen", "--capture-fullscreen": try setMode(.fullscreen)
        case "scroll", "--scroll": try setMode(.scroll)
        case "--copy": req.quickCopy = true
        case "--save": req.quickSave = true
        case "--annotate": req.annotate = true
        case "--clipboard": clipboard = true
        case "--editor":
            i += 1
            guard i < args.count, let m = Config.EditorMode(rawValue: args[i]) else { throw UsageError(message: "--editor takes overlay or window") }
            req.editorMode = m
        case "--file":
            i += 1
            guard i < args.count else { throw UsageError(message: "--file needs a path") }
            file = resolve(args[i], cwd: cwd)
        default:
            if a.hasPrefix("-") { throw UsageError(message: "unknown option \(a)") }
            if file != nil { throw UsageError(message: "only one image may be given") }
            file = resolve(a, cwd: cwd)
        }
        i += 1
    }
    if (file != nil || clipboard) && (req.quick || sawMode) {
        throw UsageError(message: "--copy/--save and capture modes cannot be combined with an image")
    }
    if let file { return .file(file, req.editorMode) }
    if clipboard { return .clipboard(req.editorMode) }
    return .capture(req)
}

func resolve(_ path: String, cwd: String) -> URL {
    if path.hasPrefix("file://"), let u = URL(string: path) { return u }
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
    return URL(fileURLWithPath: cwd).appendingPathComponent(expanded).standardizedFileURL
}

@MainActor
func run(_ command: Command) {
    let app = AppController.shared
    switch command {
    case .idle: break
    case .capture(let req): app.capture(req)
    case .file(let url, let mode): app.openFile(url, editorMode: mode)
    case .clipboard(let mode): app.openClipboard(editorMode: mode)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var pending: Command = .idle

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppController.shared.start()
            DistributedNotificationCenter.default().addObserver(forName: commandNotification, object: bundleId, queue: .main) { note in
                guard let args = note.userInfo?["args"] as? [String], let cwd = note.userInfo?["cwd"] as? String else { return }
                MainActor.assumeIsolated {
                    if let cmd = try? parse(args, cwd: cwd) { run(cmd) }
                }
            }
            run(pending)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for u in urls where u.isFileURL { AppController.shared.openFile(u, editorMode: nil) }
        }
    }

    /// macsnap://capture?mode=region&annotate=1 · macsnap://clipboard · macsnap://open?path=/x.png
    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let comps = URLComponents(string: s) else { return }
        let q = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        var args: [String] = []
        switch comps.host ?? "" {
        case "capture":
            args.append(q["mode"] ?? "smart")
            if q["annotate"] == "1" { args.append("--annotate") }
            if let e = q["editor"] { args += ["--editor", e] }
            if q["copy"] == "1" { args.append("--copy") }
            if q["save"] == "1" { args.append("--save") }
        case "clipboard": args.append("--clipboard")
        case "open": if let p = q["path"] { args += ["--file", p] }
        default: return
        }
        MainActor.assumeIsolated {
            if let cmd = try? parse(args, cwd: NSHomeDirectory()) { run(cmd) }
        }
    }
}

// MARK: Entry

if let dir = ProcessInfo.processInfo.environment["MACSNAP_UI_SNAPSHOT"] {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        DebugSnapshots.run(dir: URL(fileURLWithPath: dir),
                           fixture: ProcessInfo.processInfo.environment["MACSNAP_UI_FIXTURE"].map { URL(fileURLWithPath: $0) })
    }
    exit(0)
}

var args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
let launchedByUs = args.first == launchedMarker
if launchedByUs { args.removeFirst() }
// Xcode/LaunchServices may pass -NSDocumentRevisionsDebugMode etc.
if let i = args.firstIndex(of: "-NSDocumentRevisionsDebugMode") { args.removeSubrange(i...min(i + 1, args.count - 1)) }

if args.contains("--help") || args.contains("-h") {
    print(usage)
    exit(0)
}
if args.contains("--version") {
    print("macsnap \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
    exit(0)
}

let cwd = FileManager.default.currentDirectoryPath
var command: Command = .idle
if !args.isEmpty {
    do {
        command = try parse(args, cwd: cwd)
    } catch let e as UsageError {
        FileHandle.standardError.write("macsnap: \(e.message)\n\n\(usage)\n".data(using: .utf8)!)
        exit(2)
    }
    if case .file(let url, _) = command, !FileManager.default.isReadableFile(atPath: url.path) {
        FileHandle.standardError.write("macsnap: cannot read \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
}

let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).filter { $0.processIdentifier != getpid() }
if !others.isEmpty {
    // One instance: hand the command to it (a capture toggles its overlay).
    if !args.isEmpty {
        DistributedNotificationCenter.default().postNotificationName(commandNotification, object: bundleId,
                                                                     userInfo: ["args": args, "cwd": cwd], deliverImmediately: true)
    }
    exit(0)
}

let isBundled = Bundle.main.bundleURL.pathExtension == "app"
if !args.isEmpty, !launchedByUs, isBundled {
    // Started from a terminal: relaunch through LaunchServices so the agent
    // outlives the shell, carrying the command along.
    let cfg = NSWorkspace.OpenConfiguration()
    var forwarded = args
    if case .file(let url, let mode) = command {
        forwarded = ["--file", url.path] + (mode.map { ["--editor", $0.rawValue] } ?? [])
    }
    cfg.arguments = [launchedMarker] + forwarded
    cfg.activates = false
    cfg.createsNewApplicationInstance = false
    let sema = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, error in
        if let error { FileHandle.standardError.write("macsnap: \(error.localizedDescription)\n".data(using: .utf8)!) }
        sema.signal()
    }
    sema.wait()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
delegate.pending = command
app.delegate = delegate
app.run()
