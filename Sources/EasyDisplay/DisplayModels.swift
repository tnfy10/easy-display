import Foundation
import CoreGraphics

struct DisplayIdentity: Hashable, Codable {
    let vendor: UInt32
    let product: UInt32
    let serial: UInt32
    var modelKey: String { String(format: "%04x-%04x", vendor, product) }
}

struct DisplayMode: Identifiable, Hashable {
    let id: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    var isHiDPI: Bool { pixelWidth > width && pixelHeight > height }
    var sizeLabel: String { "\(width) × \(height)" }
    var frequencyLabel: String { refreshRate > 0 ? "\(refreshRate.formatted(.number.precision(.fractionLength(0...2)))) Hz" : "가변 / 시스템 기본" }
    var resolutionKey: String { "\(width)x\(height)-\(isHiDPI)" }
    var selectionKey: String { "\(resolutionKey)-\(Int((refreshRate * 100).rounded()))" }

    init(_ mode: CGDisplayMode) {
        id = mode.ioDisplayModeID
        width = mode.width; height = mode.height
        pixelWidth = mode.pixelWidth; pixelHeight = mode.pixelHeight
        refreshRate = mode.refreshRate
    }

    init(id: Int32, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double) {
        self.id = id; self.width = width; self.height = height
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.refreshRate = refreshRate
    }

    static func distinct(_ modes: [DisplayMode]) -> [DisplayMode] {
        var keys = Set<String>()
        return modes.filter { keys.insert($0.selectionKey).inserted }.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.height != $1.height { return $0.height > $1.height }
            if $0.isHiDPI != $1.isHiDPI { return $0.isHiDPI }
            return $0.refreshRate > $1.refreshRate
        }
    }
}

struct PhysicalSignal {
    let width: Int
    let height: Int
    let refreshRate: Double?
    var label: String {
        let hz = refreshRate.map { " · \($0.formatted(.number.precision(.fractionLength(0...2)))) Hz" } ?? ""
        return "\(width) × \(height)\(hz)"
    }
}

struct ConnectedDisplay: Identifiable {
    let id: CGDirectDisplayID
    let uuid: String
    let identity: DisplayIdentity
    let name: String
    let isBuiltin: Bool
    let isMain: Bool
    let isMirrored: Bool
    let active: DisplayMode
    let modes: [DisplayMode]
    let signal: PhysicalSignal?
    let nativeWidth: Int
    let nativeHeight: Int
    /// Global desktop frame (top-left origin, points). Mirrored displays share their source's frame.
    let bounds: CGRect
    /// The display whose contents this one shows, when it is part of a mirror set.
    let mirrorOf: CGDirectDisplayID?
    let supportsHDR: Bool
    let hdrEnabled: Bool
    let canRotate: Bool
    /// Clockwise degrees: 0, 90, 180 or 270.
    let rotation: Int
    var isPortrait: Bool { rotation == 90 || rotation == 270 }
    /// Signal color formats macOS offers for the current mode (pixel encoding, range, bit depth).
    let colorModes: [ColorOutputMode]
    let colorMode: ColorOutputMode?
    /// Choices that match the current HDR state; switching HDR itself is the HDR card's job.
    var selectableColorModes: [ColorOutputMode] {
        colorModes.filter { $0.isHDR == (colorMode?.isHDR ?? false) }.sorted()
    }

    var matchingResolutions: [DisplayMode] {
        var seen = Set<String>()
        return modes.filter { seen.insert($0.resolutionKey).inserted }
    }
}

enum DisplayRotation: Int, CaseIterable, Identifiable {
    case standard = 0, clockwise = 90, upsideDown = 180, counterClockwise = 270
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .standard: "가로"
        case .clockwise: "세로 (90°)"
        case .upsideDown: "뒤집기 (180°)"
        case .counterClockwise: "세로 (270°)"
        }
    }
}

/// One WindowServer "output mode link description": how pixels travel over the cable.
/// Field order matches SkyLight's 16-byte struct: bit depth, full range flag, EOTF, pixel encoding.
struct ColorOutputMode: Hashable, Identifiable, Comparable {
    enum Encoding: UInt32 {
        case rgb = 0, ycbcr444 = 1, ycbcr422 = 2, ycbcr420 = 3
        var label: String {
            switch self {
            case .rgb: "RGB"
            case .ycbcr444: "YCbCr 4:4:4"
            case .ycbcr422: "YCbCr 4:2:2"
            case .ycbcr420: "YCbCr 4:2:0"
            }
        }
    }

    let depth: UInt32
    /// 1 = full range (0–255). YCbCr is always sent as limited range.
    let range: UInt32
    /// 0 = SDR gamma, 2 = PQ (HDR).
    let eotf: UInt32
    let encoding: UInt32

    var id: String { argument }
    var isRGB: Bool { encoding == Encoding.rgb.rawValue }
    var isFullRange: Bool { range == 1 }
    var isHDR: Bool { eotf != 0 }
    var encodingLabel: String { Encoding(rawValue: encoding)?.label ?? "형식 \(encoding)" }
    var rangeLabel: String { isFullRange ? "Full" : "Limited" }
    var label: String { "\(encodingLabel) · \(rangeLabel) · \(depth)비트\(isHDR ? " · HDR" : "")" }

    /// Compact form used to hand the original mode to the recovery watchdog.
    var argument: String { "\(depth),\(range),\(eotf),\(encoding)" }

    init(depth: UInt32, range: UInt32, eotf: UInt32, encoding: UInt32) {
        self.depth = depth; self.range = range; self.eotf = eotf; self.encoding = encoding
    }

    init?(argument: String) {
        let parts = argument.split(separator: ",").compactMap { UInt32($0) }
        guard parts.count == 4 else { return nil }
        self.init(depth: parts[0], range: parts[1], eotf: parts[2], encoding: parts[3])
    }

    /// RGB first, then full before limited, then higher bit depth.
    static func < (a: Self, b: Self) -> Bool {
        if a.encoding != b.encoding { return a.encoding < b.encoding }
        if a.range != b.range { return a.range > b.range }
        if a.depth != b.depth { return a.depth > b.depth }
        return a.eotf < b.eotf
    }

    /// The RGB mode for the requested range, keeping the current bit depth and HDR state when possible.
    static func rgbTarget(fullRange: Bool, in modes: [Self], current: Self?) -> Self? {
        let candidates = modes.filter { $0.isRGB && $0.isFullRange == fullRange && $0.isHDR == (current?.isHDR ?? false) }
        return candidates.first { $0.depth == current?.depth } ?? candidates.max { $0.depth < $1.depth }
    }
}

struct CustomResolution: Equatable, Hashable, Identifiable {
    let width: Int
    let height: Int
    var id: String { "\(width)x\(height)" }
    var label: String { "\(width) × \(height)" }

    static func parse(_ input: String) throws -> [CustomResolution] {
        let normalized = input.replacingOccurrences(of: "×", with: "x").lowercased()
        let entries = normalized.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
        guard !entries.isEmpty, entries.count <= 24 else {
            throw DisplayError.message("해상도는 1~24개를 입력해 주세요.")
        }
        var result: [CustomResolution] = []
        for entry in entries {
            let parts = entry.replacingOccurrences(of: " ", with: "").split(separator: "x", omittingEmptySubsequences: false)
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
                  (640...3840).contains(w), (360...2160).contains(h) else {
                throw DisplayError.message("해상도는 640×360~3840×2160 범위로 입력해 주세요. 예: 1920x1080, 2048x1152")
            }
            let res = CustomResolution(width: w, height: h)
            if !result.contains(res) { result.append(res) }
        }
        return result
    }
}

enum DisplayError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}
