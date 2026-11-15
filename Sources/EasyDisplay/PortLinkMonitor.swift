import Foundation
import IOKit

/// One video transport on a physical Mac port, as reported by IOKit.
///
/// A port whose cable is detected (hot-plug high) but which never brings up a sink
/// means the Mac and monitor failed to negotiate a link. macOS then never lists the
/// monitor at all, so CoreGraphics alone cannot reveal the failure.
struct PortLinkSample: Equatable {
    /// Stable across re-plugging, unlike the registry entry ID.
    let key: String
    let portType: String
    let portNumber: Int
    let hotPlug: Bool
    let sinkCount: Int
    let tunneled: Bool
    let productName: String?

    var isStalled: Bool { hotPlug && sinkCount == 0 }

    var portLabel: String {
        switch portType {
        case "HDMI": return "HDMI 포트"
        case "USB-C": return tunneled ? "USB-C 포트 \(portNumber) (썬더볼트 독)" : "USB-C 포트 \(portNumber)"
        default: return "\(portType) 포트 \(portNumber)"
        }
    }

    /// Parses `IOPortTransportStateDisplayPort` properties. Unknown layouts yield nil.
    init?(properties p: [String: Any]) {
        guard let type = (p["ParentBuiltInPortTypeDescription"] ?? p["ParentPortTypeDescription"]) as? String,
              let number = (p["ParentBuiltInPortNumber"] ?? p["ParentPortNumber"]) as? NSNumber,
              let sinks = p["SinkCount"] as? NSNumber else { return nil }
        let hpd: Bool
        if let description = p["HPD_StateDescription"] as? String { hpd = description.caseInsensitiveCompare("High") == .orderedSame }
        else if let state = p["HPD_State"] as? NSNumber { hpd = state.intValue == 2 }
        else { return nil }
        self.init(portType: type, portNumber: number.intValue, hotPlug: hpd, sinkCount: sinks.intValue,
                  tunneled: (p["Tunneled"] as? Bool) ?? false, productName: p["ProductName"] as? String)
    }

    init(portType: String, portNumber: Int, hotPlug: Bool, sinkCount: Int, tunneled: Bool = false, productName: String? = nil) {
        key = "\(portType)-\(portNumber)"
        self.portType = portType; self.portNumber = portNumber
        self.hotPlug = hotPlug; self.sinkCount = sinkCount
        self.tunneled = tunneled; self.productName = productName
    }
}

struct StalledPort: Identifiable, Equatable {
    let id: String
    let label: String
    let since: Date
}

/// Reports a port only after it has stayed stalled for `threshold`, because every
/// normal plug-in briefly shows hot-plug high before the link comes up.
struct PortLinkTracker {
    var threshold: TimeInterval = 8
    private(set) var firstStalled: [String: Date] = [:]

    mutating func update(_ samples: [PortLinkSample], now: Date = Date()) -> [StalledPort] {
        let stalled = samples.filter(\.isStalled)
        let keys = Set(stalled.map(\.key))
        firstStalled = firstStalled.filter { keys.contains($0.key) }
        for sample in stalled where firstStalled[sample.key] == nil { firstStalled[sample.key] = now }
        return stalled.compactMap { sample in
            guard let since = firstStalled[sample.key], now.timeIntervalSince(since) >= threshold else { return nil }
            return StalledPort(id: sample.key, label: sample.portLabel, since: since)
        }.sorted { $0.id < $1.id }
    }
}

enum PortLinkReader {
    /// Not public API; an OS without this class simply reports no ports and no warning.
    static func samples() -> [PortLinkSample] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPortTransportStateDisplayPort"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [PortLinkSample] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                  let sample = PortLinkSample(properties: properties) else { continue }
            result.append(sample)
        }
        return result
    }
}
