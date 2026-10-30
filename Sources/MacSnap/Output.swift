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

    static func recognize(_ image: CGImage, fast: Bool = false) async -> [Line] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = fast ? .fast : .accurate
                req.usesLanguageCorrection = !fast
                if let langs = languages { req.recognitionLanguages = langs } else { req.automaticallyDetectsLanguage = true }
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                try? handler.perform([req])
                let lines = (req.results ?? []).compactMap { obs -> Line? in
                    guard let s = obs.topCandidates(1).first?.string else { return nil }
                    let b = obs.boundingBox
                    return Line(text: s, box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
                }
                cont.resume(returning: lines)
            }
        }
    }

    /// Lines joined top-to-bottom.
    static func text(_ lines: [Line]) -> String {
        lines.sorted { abs($0.box.minY - $1.box.minY) > 0.01 ? $0.box.minY < $1.box.minY : $0.box.minX < $1.box.minX }
            .map(\.text).joined(separator: "\n")
    }
}
