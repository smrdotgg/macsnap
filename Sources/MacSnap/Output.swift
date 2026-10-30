import AppKit
import MacSnapCore
@preconcurrency import Vision

enum Output {
    static func copyPNG(_ data: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
    }

    static func copyText(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The image currently on the clipboard, if any.
    static func clipboardImage() -> ImageFiles.Loaded? {
        let pb = NSPasteboard.general
        for t in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")] {
            if let d = pb.data(forType: t), d.count < 256 << 20, let img = ImageFiles.load(data: d) { return img }
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let u = urls.first, let img = ImageFiles.load(url: u) { return img }
        if let img = NSImage(pasteboard: pb), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let rep = img.representations.first
            let scale = rep.map { CGFloat($0.pixelsWide) / max(1, $0.size.width) } ?? 1
            return ImageFiles.Loaded(image: ImageFiles.normalized(cg) ?? cg, scale: max(1, scale.rounded()))
        }
        return nil
    }

    /// Private runtime directory for temporary preview files.
    static var runtimeDir: URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("MacSnap", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return d
    }
}

/// On-device text recognition through Vision.
enum OCR {
    struct Line {
        var text: String
        /// Normalized, top-left origin.
        var box: CGRect
    }

    static var languages: [String]? {
        let env = ProcessInfo.processInfo.environment
        guard let v = env["MACSNAP_OCR_LANGS"], !v.isEmpty else { return nil }
        return v.split(whereSeparator: { $0 == "+" || $0 == "," }).map(String.init)
    }

    struct Attempt {
        var revision: Int?
        var level: VNRequestTextRecognitionLevel
        var label: String
    }

    /// Recognizes text with Vision's fast recognizer.
    ///
    /// Not the accurate one: on macOS 27.0.1 the accurate models spend ~28 s
    /// compiling on the first request of a process (blocking every other
    /// Vision request meanwhile), then fail each later request with an e5rt
    /// Neural Engine error. Fast recognition answers in tens of milliseconds
    /// and reads screenshot text well. Language correction is off: it doesn't
    /// fix splits and it rewrites identifiers ("MacSnap" → "Macsnap").
    static func recognize(_ source: CGImage, timeout: Double = 6) async throws -> [Line] {
        let image = upscaledForRecognition(source)
        let attempts = [Attempt(revision: nil, level: .fast, label: "fast")]
        DevLog.write("OCR start \(source.width)x\(source.height) → \(image.width)x\(image.height)")
        let overall = DispatchTime.now()
        var lastError: Error = NSError(domain: "MacSnap", code: 4, userInfo: [NSLocalizedDescriptionKey: "No recognizer succeeded"])
        for attempt in attempts {
            let t0 = DispatchTime.now()
            do {
                let lines = try await run(attempt, on: image, timeout: timeout)
                DevLog.write("OCR \(attempt.label) ok: \(lines.count) lines in \(DevLog.since(t0)) (total \(DevLog.since(overall)))")
                return lines
            } catch {
                DevLog.write("OCR \(attempt.label) failed after \(DevLog.since(t0)): \(error)")
                lastError = error
            }
        }
        DevLog.write("OCR gave up after \(DevLog.since(overall))")
        throw lastError
    }

    /// Fast recognition misses small glyphs; enlarging small captures toward
    /// ~3600 px on the long side (at most 3×) recovers most of them. In tests
    /// a downscaled screenshot went from 9 lines read at 1× to 44 at 3×, still
    /// in about 0.1 s. Boxes are normalized, so callers are unaffected.
    static func upscaledForRecognition(_ img: CGImage) -> CGImage {
        let long = CGFloat(max(img.width, img.height))
        let k = min(3, 3600 / max(1, long))
        guard k > 1.15 else { return img }
        let w = Int(CGFloat(img.width) * k), h = Int(CGFloat(img.height) * k)
        guard w * h <= 40_000_000, let ctx = CaptureRenderer.makeContext(width: w, height: h) else { return img }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    private static func run(_ attempt: Attempt, on image: CGImage, timeout: Double) async throws -> [Line] {
        let req = VNRecognizeTextRequest()
        if let r = attempt.revision { req.revision = r }
        req.recognitionLevel = attempt.level
        req.usesLanguageCorrection = false
        if let langs = languages {
            req.recognitionLanguages = langs
        } else if req.revision >= VNRecognizeTextRequestRevision3 {
            req.automaticallyDetectsLanguage = true
        }
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if done { return false }
                done = true
                return true
            }
        }
        let once = Once()
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
                    let lines = (req.results ?? []).compactMap { obs -> Line? in
                        guard let s = obs.topCandidates(1).first?.string else { return nil }
                        let b = obs.boundingBox
                        return Line(text: s, box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
                    }
                    if once.claim() { cont.resume(returning: lines) }
                } catch {
                    if once.claim() { cont.resume(throwing: error) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard once.claim() else { return }
                req.cancel()
                cont.resume(throwing: NSError(domain: "MacSnap", code: 5, userInfo: [NSLocalizedDescriptionKey: "timed out after \(timeout)s"]))
            }
        }
    }

    /// Lines joined top-to-bottom.
    static func text(_ lines: [Line]) -> String {
        lines.sorted { abs($0.box.minY - $1.box.minY) > 0.01 ? $0.box.minY < $1.box.minY : $0.box.minX < $1.box.minX }
            .map(\.text).joined(separator: "\n")
    }
}
