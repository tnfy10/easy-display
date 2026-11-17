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

    /// A line where a snapped display's edge or center lines up with another display's.
    struct Guide: Equatable {
        enum Axis: Equatable { case vertical, horizontal }
        let axis: Axis
        /// x for vertical guides, y for horizontal ones.
        let position: CGFloat
        /// Extent along the line, covering both displays.
        let start: CGFloat
        let end: CGFloat
    }

    /// Guides to draw for `rect` at its snapped place: shared edges plus aligned edges and centers.
    static func guides(for rect: CGRect, others: [CGRect]) -> [Guide] {
        var result: [Guide] = []
        func add(_ guide: Guide) { if !result.contains(guide) { result.append(guide) } }
        for other in others {
            for x in [rect.minX, rect.midX, rect.maxX] where [other.minX, other.midX, other.maxX].contains(where: { abs($0 - x) < 0.5 }) {
                add(Guide(axis: .vertical, position: x, start: min(rect.minY, other.minY), end: max(rect.maxY, other.maxY)))
            }
            for y in [rect.minY, rect.midY, rect.maxY] where [other.minY, other.midY, other.maxY].contains(where: { abs($0 - y) < 0.5 }) {
                add(Guide(axis: .horizontal, position: y, start: min(rect.minX, other.minX), end: max(rect.maxX, other.maxX)))
            }
        }
        return result
    }

    /// Drops display `id` near `dropped` and returns every display's resulting frame, or nil when it cannot be placed.
    /// Besides snapping the dropped display, displays left detached (e.g. after pulling the middle one of three
    /// out of a row) are pulled back into contact; otherwise macOS rearranges them on its own.
    static func drop(_ id: String, at dropped: CGRect, frames: [String: CGRect]) -> [String: CGRect]? {
        let others = frames.filter { $0.key != id }.sorted { $0.key < $1.key }.map(\.value)
        guard let origin = snap(dropped, others: others) else { return nil }
        var result = frames
        result[id] = CGRect(origin: origin, size: dropped.size)
        return compacted(result, anchor: id)
    }

    /// Two displays are joined when they share part of an edge; touching only at a corner does not count.
    static func touches(_ a: CGRect, _ b: CGRect) -> Bool {
        let side = (abs(a.maxX - b.minX) < 0.5 || abs(b.maxX - a.minX) < 0.5) && min(a.maxY, b.maxY) - max(a.minY, b.minY) > 0.5
        let stacked = (abs(a.maxY - b.minY) < 0.5 || abs(b.maxY - a.minY) < 0.5) && min(a.maxX, b.maxX) - max(a.minX, b.minX) > 0.5
        return side || stacked
    }

    /// Keys reachable from `start` through touching displays.
    static func connected(_ frames: [String: CGRect], from start: String) -> Set<String> {
        var seen: Set<String> = [start]
        var queue = [start]
        while let key = queue.popLast(), let rect = frames[key] {
            for (other, frame) in frames where !seen.contains(other) && touches(rect, frame) {
                seen.insert(other)
                queue.append(other)
            }
        }
        return seen
    }

    /// Moves detached groups of displays, each as a unit, the shortest distance that joins them to `anchor`'s group.
    /// The anchor's group never moves. Groups that cannot be joined without overlapping stay where they are.
    static func compacted(_ frames: [String: CGRect], anchor: String) -> [String: CGRect] {
        guard frames[anchor] != nil else { return frames }
        var frames = frames
        while true {
            let joined = connected(frames, from: anchor)
            var detached = frames.keys.filter { !joined.contains($0) }.sorted()
            guard !detached.isEmpty else { return frames }
            var groups: [Set<String>] = []
            while let key = detached.first {
                let group = connected(frames.filter { !joined.contains($0.key) }, from: key)
                groups.append(group)
                detached.removeAll { group.contains($0) }
            }
            var best: (group: Set<String>, delta: CGVector, distance: CGFloat)?
            for group in groups {
                let fixed = frames.filter { !group.contains($0.key) }.map(\.value)
                for key in group.sorted() {
                    let r = frames[key]!
                    for target in joined.sorted().compactMap({ frames[$0] }) {
                        let y = slide(r.minY, length: r.height, along: target.minY, otherLength: target.height, threshold: 0)
                        let x = slide(r.minX, length: r.width, along: target.minX, otherLength: target.width, threshold: 0)
                        let candidates = [CGPoint(x: target.maxX, y: y), CGPoint(x: target.minX - r.width, y: y),
                                          CGPoint(x: x, y: target.maxY), CGPoint(x: x, y: target.minY - r.height)]
                        for candidate in candidates {
                            let delta = CGVector(dx: (candidate.x - r.minX).rounded(), dy: (candidate.y - r.minY).rounded())
                            let distance = hypot(delta.dx, delta.dy)
                            if let best, distance >= best.distance { continue }
                            let moved = group.compactMap { frames[$0]?.offsetBy(dx: delta.dx, dy: delta.dy) }
                            if moved.contains(where: { m in fixed.contains { overlaps($0, m) } }) { continue }
                            best = (group, delta, distance)
                        }
                    }
                }
            }
            guard let best else { return frames }
            for key in best.group { frames[key] = frames[key]!.offsetBy(dx: best.delta.dx, dy: best.delta.dy) }
        }
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

    /// Pulls independent displays back into contact after a display left the desktop to become a mirror,
    /// e.g. the middle one of three. `anchor` stays put; entries without an origin or size are left to macOS.
    static func closingGaps(_ entries: [LayoutEntry], sizes: [String: CGSize], anchor: String) -> [LayoutEntry] {
        var frames: [String: CGRect] = [:]
        for entry in entries where entry.mirrorOf == nil {
            if let origin = entry.origin, let size = sizes[entry.uuid] { frames[entry.uuid] = CGRect(origin: origin, size: size) }
        }
        let compacted = compacted(frames, anchor: anchor)
        return entries.map { entry in
            var entry = entry
            if let frame = compacted[entry.uuid] { entry.origin = frame.origin }
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
