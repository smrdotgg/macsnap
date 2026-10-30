import CoreGraphics
import Foundation

/// Aligns successive captures of a scrolling region and stitches them into
/// one tall (or wide) image. Pure and offline-testable.
///
/// Every frame is reduced to per-line hashes (rows for vertical scrolling,
/// columns for horizontal). Static bands at the leading and trailing edges
/// (sticky headers, footers) are found by position-wise equality; the scroll
/// distance is the offset most voted for by distinctive lines in between.
public final class Stitcher {
    public enum Axis: String, Sendable { case vertical, horizontal }

    public enum Outcome: Equatable, Sendable {
        case first
        case moved(Int)
        case unchanged
        /// No confident alignment (e.g. scrolled too far between frames).
        case lost
    }

    struct Frame {
        var image: CGImage
        var hashes: [UInt64]
        var informative: [Bool]
        /// Content coordinate of line 0.
        var position: Int
    }

    public let axis: Axis
    private var frames: [Frame] = []
    private var lead = Int.max
    private var trail = Int.max
    public private(set) var maxFrames: Int

    public init(axis: Axis = .vertical, maxFrames: Int = 120) {
        self.axis = axis
        self.maxFrames = maxFrames
    }

    public var frameCount: Int { frames.count }
    public var isFull: Bool { frames.count >= maxFrames }

    /// Total stitched length in pixels along the scroll axis.
    public var stitchedLength: Int {
        guard let first = frames.first, let last = frames.last else { return 0 }
        return last.position - first.position + lineCount(first.image)
    }

    func lineCount(_ img: CGImage) -> Int { axis == .vertical ? img.height : img.width }

    @discardableResult
    public func add(_ image: CGImage) -> Outcome {
        guard let (hashes, informative) = lineHashes(image) else { return .lost }
        guard let prev = frames.last else {
            frames.append(Frame(image: image, hashes: hashes, informative: informative, position: 0))
            return .first
        }
        guard prev.hashes.count == hashes.count else { return .lost }
        if prev.hashes == hashes { return .unchanged }
        let n = hashes.count
        var l = 0
        while l < n, prev.hashes[l] == hashes[l] { l += 1 }
        var t = 0
        while t < n - l, prev.hashes[n - 1 - t] == hashes[n - 1 - t] { t += 1 }
        guard let d = offset(prev: prev, hashes: hashes, informative: informative, lead: l, trail: t) else { return .lost }
        lead = min(lead, l)
        trail = min(trail, t)
        if frames.count >= maxFrames { return .lost }
        frames.append(Frame(image: image, hashes: hashes, informative: informative, position: prev.position + d))
        return .moved(d)
    }

    private func offset(prev: Frame, hashes: [UInt64], informative: [Bool], lead l: Int, trail t: Int) -> Int? {
        let n = hashes.count
        let lo = l, hi = n - t
        guard hi - lo > 8 else { return nil }
        var index: [UInt64: [Int]] = [:]
        for i in lo..<hi where prev.informative[i] {
            index[prev.hashes[i], default: []].append(i)
        }
        var votes: [Int: Int] = [:]
        var considered = 0
        for j in lo..<hi where informative[j] {
            guard let hits = index[hashes[j]], hits.count <= 16 else { continue }
            considered += 1
            for i in hits where i > j { votes[i - j, default: 0] += 1 }
        }
        guard let (best, count) = votes.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else { return nil }
        let overlap = hi - lo - best
        guard overlap > 0 else { return nil }
        // Verify: most informative lines in the overlap must agree.
        var agree = 0, total = 0
        for j in lo..<(lo + overlap) where informative[j] {
            total += 1
            if hashes[j] == prev.hashes[j + best] { agree += 1 }
        }
        guard count >= 3, total > 0, Double(agree) / Double(total) >= 0.75 else { return nil }
        _ = considered
        return best
    }

    /// Hash per line; "informative" lines are not a single flat color.
    func lineHashes(_ image: CGImage) -> ([UInt64], [Bool])? {
        let w = image.width, h = image.height
        guard let ctx = CaptureRenderer.makeContext(width: w, height: h), w > 0, h > 0 else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        let p = data.bindMemory(to: UInt8.self, capacity: bpr * h)
        let lines = axis == .vertical ? h : w
        let along = axis == .vertical ? w : h
        var hashes = [UInt64](repeating: 0, count: lines)
        var info = [Bool](repeating: false, count: lines)
        for line in 0..<lines {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            var minL = 255, maxL = 0
            for k in 0..<along {
                let o = axis == .vertical ? line * bpr + k * 4 : k * bpr + line * 4
                let r = p[o], g = p[o + 1], b = p[o + 2]
                hash = (hash ^ UInt64(r)) &* 0x100_0000_01b3
                hash = (hash ^ UInt64(g)) &* 0x100_0000_01b3
                hash = (hash ^ UInt64(b)) &* 0x100_0000_01b3
                let lum = (Int(r) * 3 + Int(g) * 6 + Int(b)) / 10
                if lum < minL { minL = lum }
                if lum > maxL { maxL = lum }
            }
            hashes[line] = hash
            info[line] = maxL - minL > 12
        }
        return (hashes, info)
    }

    /// The stitched image: leading band from the first frame, scrolled content
    /// from each frame's middle, trailing band from the last frame.
    public func compose() -> CGImage? {
        guard let first = frames.first, let last = frames.last else { return nil }
        if frames.count == 1 { return first.image }
        let n = lineCount(first.image)
        let l = lead == .max ? 0 : lead, t = trail == .max ? 0 : trail
        let total = last.position + n
        let cross = axis == .vertical ? first.image.width : first.image.height
        let (cw, ch) = axis == .vertical ? (cross, total) : (total, cross)
        guard let ctx = CaptureRenderer.makeContext(width: cw, height: ch) else { return nil }
        ctx.interpolationQuality = .none

        func blit(_ img: CGImage, from a: Int, to b: Int, at pos: Int) {
            guard b > a else { return }
            let src = axis == .vertical ? CGRect(x: 0, y: a, width: cross, height: b - a) : CGRect(x: a, y: 0, width: b - a, height: cross)
            guard let part = img.cropping(to: src) else { return }
            let dst = axis == .vertical
                ? CGRect(x: 0, y: ch - pos - (b - a), width: cross, height: b - a)
                : CGRect(x: pos, y: 0, width: b - a, height: cross)
            ctx.draw(part, in: dst)
        }

        // Leading band and the first frame's middle.
        blit(first.image, from: 0, to: n - t, at: 0)
        var covered = n - t // content coordinate up to which output is filled
        for f in frames.dropFirst() {
            let end = f.position + n - t
            guard end > covered else { continue }
            let startLine = max(l, covered - f.position)
            blit(f.image, from: startLine, to: n - t, at: f.position + startLine)
            covered = end
        }
        // Trailing band from the last frame.
        blit(last.image, from: n - t, to: n, at: last.position + n - t)
        return ctx.makeImage()
    }
}
