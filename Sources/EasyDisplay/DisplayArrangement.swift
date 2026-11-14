import CoreGraphics
import Foundation

/// One display's place in the desktop. `origin == nil` lets macOS choose the position,
/// `modeID == nil` leaves the current mode untouched.
struct LayoutEntry: Codable, Equatable {
    let uuid: String
    var origin: CGPoint?
    var mirrorOf: String?
    var modeID: Int32?
}

/// Pure layout math, kept free of CoreGraphics calls so it can be unit-tested.
enum DisplayArrangement {
    /// Places `moving` against an edge of one of `others`, as close as possible to where it was dropped,
    /// without overlapping any display. Returns nil when no valid spot exists.
    static func snap(_ moving: CGRect, others: [CGRect], threshold: CGFloat = 48) -> CGPoint? {
        guard !others.isEmpty else { return moving.origin }
        var best: (point: CGPoint, distance: CGFloat)?
        for other in others {
            let y = slide(moving.minY, length: moving.height, along: other.minY, otherLength: other.height, threshold: threshold)
            let x = slide(moving.minX, length: moving.width, along: other.minX, otherLength: other.width, threshold: threshold)
            let candidates = [
                CGPoint(x: other.maxX, y: y), CGPoint(x: other.minX - moving.width, y: y),
                CGPoint(x: x, y: other.maxY), CGPoint(x: x, y: other.minY - moving.height)
            ]
            for candidate in candidates {
                let rect = CGRect(origin: candidate, size: moving.size)
                if others.contains(where: { overlaps($0, rect) }) { continue }
                let distance = hypot(candidate.x - moving.minX, candidate.y - moving.minY)
                if best == nil || distance < best!.distance { best = (candidate, distance) }
            }
        }
        return best.map { CGPoint(x: $0.point.x.rounded(), y: $0.point.y.rounded()) }
    }

    /// Slides along a shared edge while keeping some overlap, snapping to aligned edges or centers.
    static func slide(_ start: CGFloat, length: CGFloat, along otherStart: CGFloat, otherLength: CGFloat, threshold: CGFloat) -> CGFloat {
        let minOverlap = min(length, otherLength, 64)
        let value = min(max(start, otherStart - length + minOverlap), otherStart + otherLength - minOverlap)
        let targets = [otherStart, otherStart + otherLength - length, otherStart + (otherLength - length) / 2]
        guard let nearest = targets.min(by: { abs($0 - value) < abs($1 - value) }), abs(nearest - value) <= threshold else { return value }
        return nearest
    }

    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        return !i.isNull && i.width > 0.5 && i.height > 0.5
    }

    /// macOS defines the main display as the one at (0, 0); shift everything so `main` lands there.
    static func normalized(_ origins: [String: CGPoint], main: String) -> [String: CGPoint] {
        guard let base = origins[main] else { return origins }
        return origins.mapValues { CGPoint(x: $0.x - base.x, y: $0.y - base.y) }
    }

    /// Makes `display` show the contents of `master` (or become independent when nil).
    static func mirroring(_ entries: [LayoutEntry], display: String, of master: String?) -> [LayoutEntry] {
        // Mirror sets are one level deep: following a mirror goes to its source.
        // If the chosen source currently mirrors `display`, the two swap roles.
        let source = master.map { m -> String in
            guard let parent = entries.first(where: { $0.uuid == m })?.mirrorOf, parent != display else { return m }
            return parent
        }
        guard source != display else { return entries }
        return entries.map { entry in
            var entry = entry
            entry.modeID = nil
            if entry.uuid == display {
                if entry.mirrorOf != source { entry.origin = nil }
                entry.mirrorOf = source
            } else if entry.uuid == source {
                // A source must be independent; on a swap it takes over the old source's place.
                entry.mirrorOf = nil
            } else if entry.mirrorOf == display, let source {
                entry.mirrorOf = source
            }
            return entry
        }
    }

    static func mirrorAll(_ entries: [LayoutEntry], to master: String) -> [LayoutEntry] {
        entries.map { entry in
            var entry = entry
            entry.modeID = nil
            if entry.uuid == master { entry.mirrorOf = nil }
            else { entry.mirrorOf = master; entry.origin = nil }
            return entry
        }
    }

    static func extendAll(_ entries: [LayoutEntry]) -> [LayoutEntry] {
        entries.map { entry in
            var entry = entry
            entry.modeID = nil
            if entry.mirrorOf != nil { entry.mirrorOf = nil; entry.origin = nil }
            return entry
        }
    }
}
