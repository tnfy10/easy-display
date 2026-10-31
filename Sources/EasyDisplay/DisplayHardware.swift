import AppKit
import CoreGraphics
import IOKit

/// Rendering dimensions from CoreGraphics are deliberately kept separate from link timing.
enum DisplayHardware {
    static func identity(_ id: CGDirectDisplayID) -> DisplayIdentity {
        .init(vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id))
    }

    static func uuid(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func displayID(uuid: String) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.first { self.uuid($0) == uuid }
    }

    static func modes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? []
    }

    static func configure(id: CGDirectDisplayID, modeID: Int32, permanent: Bool = false) throws {
        guard let mode = modes(id).first(where: { $0.ioDisplayModeID == modeID }) else {
            throw DisplayError.message("이 해상도를 더 이상 사용할 수 없습니다. 모니터 목록을 새로고침해 주세요.")
        }
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
            throw DisplayError.message("디스플레이 설정을 시작하지 못했습니다.")
        }
        let change = CGConfigureDisplayWithDisplayMode(configuration, id, mode, nil)
        guard change == .success else {
            CGCancelDisplayConfiguration(configuration)
            throw DisplayError.message("해상도를 변경하지 못했습니다. (오류 \(change.rawValue))")
        }
        let result = CGCompleteDisplayConfiguration(configuration, permanent ? .permanently : .forSession)
        guard result == .success else {
            throw DisplayError.message("설정을 적용하지 못했습니다. (오류 \(result.rawValue))")
        }
    }

    @MainActor static func displays() -> [ConnectedDisplay] {
        let links = physicalLinks()
        return NSScreen.screens.compactMap { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = n.uint32Value
            guard let active = CGDisplayCopyDisplayMode(id), let uuid = uuid(id) else { return nil }
            let identity = identity(id)
            let candidates = links.filter { $0.identity.vendor == identity.vendor && $0.identity.product == identity.product }
            let link = candidates.first { $0.identity.serial == identity.serial } ?? (candidates.count == 1 ? candidates.first : nil)
            return ConnectedDisplay(
                id: id, uuid: uuid, identity: identity, name: screen.localizedName,
                isBuiltin: CGDisplayIsBuiltin(id) != 0, isMain: CGDisplayIsMain(id) != 0,
                isMirrored: CGDisplayIsInMirrorSet(id) != 0,
                active: DisplayMode(active), modes: DisplayMode.distinct(modes(id).map(DisplayMode.init)),
                signal: link?.signal, nativeWidth: link?.nativeWidth ?? 0, nativeHeight: link?.nativeHeight ?? 0
            )
        }.sorted { $0.isMain && !$1.isMain }
    }

    private struct Link {
        let identity: DisplayIdentity
        let signal: PhysicalSignal
        let nativeWidth: Int
        let nativeHeight: Int
    }

    private static func physicalLinks() -> [Link] {
        // This IOKit class/properties are OS-specific. Unknown values remain unknown;
        // CGDisplayMode.pixelWidth is never substituted for a physical signal.
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [Link] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let attrs = property("DisplayAttributes") as? [String: Any],
                  let product = attrs["ProductAttributes"] as? [String: Any],
                  let vendor = product["LegacyManufacturerID"] as? NSNumber,
                  let model = product["ProductID"] as? NSNumber,
                  let width = property("DisplayWidth") as? NSNumber,
                  let height = property("DisplayHeight") as? NSNumber else { continue }
            let serial = (product["SerialNumber"] as? NSNumber)?.uint32Value ?? 0
            let timingID = property("DPTimingModeId") as? NSNumber
            let timings = property("TimingElements") as? [[String: Any]] ?? []
            let timing = timings.first { ($0["ID"] as? NSNumber) == timingID }
            let hz = ((timing?["VerticalAttributes"] as? [String: Any])?["PreciseSyncRate"] as? NSNumber).map { $0.doubleValue / 65536 }
            let preferred = timings.filter { ($0["IsPreferred"] as? Bool) == true }
            let native = preferred.compactMap { t -> (Int, Int)? in
                guard let h = (t["HorizontalAttributes"] as? [String: Any])?["Active"] as? Int,
                      let v = (t["VerticalAttributes"] as? [String: Any])?["Active"] as? Int else { return nil }
                return (h, v)
            }.max { $0.0 * $0.1 < $1.0 * $1.1 }
            result.append(Link(identity: .init(vendor: vendor.uint32Value, product: model.uint32Value, serial: serial),
                               signal: .init(width: width.intValue, height: height.intValue, refreshRate: hz),
                               nativeWidth: native?.0 ?? 0, nativeHeight: native?.1 ?? 0))
        }
        return result
    }
}
