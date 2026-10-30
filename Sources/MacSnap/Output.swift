import AppKit
import MacSnapCore
import Vision

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

    /// Recognizes text, newest model first. Some macOS builds fail every
    /// request on Vision's revision-3 model with an internal Neural Engine
    /// error, so a failure falls back to revision 2 (no automatic language
    /// detection, but reliable), then to fast recognition.
    static func recognize(_ image: CGImage, fast: Bool = false) async throws -> [Line] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var attempts: [(revision: Int?, level: VNRequestTextRecognitionLevel)] = [
                    (nil, fast ? .fast : .accurate),
                ]
                if !fast {
                    // Revision 2, by number: the constant is deprecated, but it's the fallback we want.
                    attempts.append((2, .accurate))
                    attempts.append((nil, .fast))
                }
                var lastError: Error?
                for attempt in attempts {
                    let req = VNRecognizeTextRequest()
                    if let r = attempt.revision { req.revision = r }
                    req.recognitionLevel = attempt.level
                    req.usesLanguageCorrection = attempt.level == .accurate
                    if let langs = languages {
                        req.recognitionLanguages = langs
                    } else if req.revision >= VNRecognizeTextRequestRevision3 {
                        req.automaticallyDetectsLanguage = true
                    }
                    do {
                        try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
                    } catch {
                        lastError = error
                        continue
                    }
                    let lines = (req.results ?? []).compactMap { obs -> Line? in
                        guard let s = obs.topCandidates(1).first?.string else { return nil }
                        let b = obs.boundingBox
                        return Line(text: s, box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
                    }
                    return cont.resume(returning: lines)
                }
                cont.resume(throwing: lastError ?? NSError(domain: "MacSnap", code: 4))
            }
        }
    }

    /// Lines joined top-to-bottom.
    static func text(_ lines: [Line]) -> String {
        lines.sorted { abs($0.box.minY - $1.box.minY) > 0.01 ? $0.box.minY < $1.box.minY : $0.box.minX < $1.box.minX }
            .map(\.text).joined(separator: "\n")
    }
}
