import AppKit
import CoreGraphics
import IOKit
import Darwin

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
        onlineIDs().first { self.uuid($0) == uuid }
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

    // MARK: HDR (private SkyLight API, the same switch System Settings uses)

    private nonisolated(unsafe) static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private typealias HDRQuery = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias HDRSetter = @convention(c) (CGDirectDisplayID, Bool) -> Void

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let skyLight, let pointer = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    /// Looked up at runtime so a future macOS without these symbols simply hides the HDR switch.
    static func supportsHDR(_ id: CGDirectDisplayID) -> Bool {
        symbol("SLSDisplaySupportsHDRMode", as: HDRQuery.self)?(id) ?? false
    }

    static func isHDREnabled(_ id: CGDirectDisplayID) -> Bool {
        symbol("SLSDisplayIsHDRModeEnabled", as: HDRQuery.self)?(id) ?? false
    }

    /// The setter returns nothing, so success is confirmed by reading the state back.
    static func setHDR(id: CGDirectDisplayID, enabled: Bool) throws {
        guard supportsHDR(id), let set = symbol("SLSDisplaySetHDRModeEnabled", as: HDRSetter.self) else {
            throw DisplayError.message("이 모니터 또는 macOS 버전에서는 HDR을 전환할 수 없습니다.")
        }
        guard isHDREnabled(id) != enabled else { return }
        set(id, enabled)
        for _ in 0..<30 {
            if isHDREnabled(id) == enabled { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw DisplayError.message("HDR을 \(enabled ? "켜지" : "끄지") 못했습니다. 케이블이나 모니터 설정에서 HDR 입력을 지원하는지 확인해 주세요.")
    }

    // MARK: Rotation (private MonitorPanel API, the same control System Settings uses)

    private nonisolated(unsafe) static let monitorPanel = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY)
    private typealias OrientationSetter = @convention(c) (AnyObject, Selector, Int32) -> Void

    /// Looked up at runtime so a future macOS without MonitorPanel simply hides the rotation control.
    private static func panelDisplay(_ id: CGDirectDisplayID) -> NSObject? {
        guard monitorPanel != nil, let managerClass = NSClassFromString("MPDisplayMgr") as? NSObject.Type else { return nil }
        let manager = managerClass.init()
        guard manager.responds(to: NSSelectorFromString("displays")),
              let displays = manager.value(forKey: "displays") as? [NSObject] else { return nil }
        return displays.first { ($0.value(forKey: "displayID") as? NSNumber)?.uint32Value == id }
    }

    static func canRotate(_ id: CGDirectDisplayID) -> Bool {
        guard let display = panelDisplay(id), display.responds(to: NSSelectorFromString("canChangeOrientation")),
              display.responds(to: NSSelectorFromString("setOrientation:")) else { return false }
        return (display.value(forKey: "canChangeOrientation") as? Bool) ?? false
    }

    /// Clockwise degrees: 0, 90, 180 or 270.
    static func rotation(_ id: CGDirectDisplayID) -> Int {
        (Int(CGDisplayRotation(id).rounded()) % 360 + 360) % 360
    }

    /// Asks for the rotation without waiting. The new value only shows up once the caller's run loop
    /// processes the reconfiguration, so the app confirms it asynchronously instead of blocking.
    static func requestRotation(id: CGDirectDisplayID, degrees: Int) throws {
        guard [0, 90, 180, 270].contains(degrees), canRotate(id), let display = panelDisplay(id) else {
            throw DisplayError.message("이 모니터 또는 macOS 버전에서는 화면 방향을 바꿀 수 없습니다.")
        }
        guard rotation(id) != degrees else { return }
        let selector = NSSelectorFromString("setOrientation:")
        let set = unsafeBitCast(display.method(for: selector), to: OrientationSetter.self)
        set(display, selector, Int32(degrees))
    }

    /// Blocking variant for the watchdog process, which has no app run loop to keep responsive.
    static func setRotation(id: CGDirectDisplayID, degrees: Int) throws {
        try requestRotation(id: id, degrees: degrees)
        let uuid = uuid(id)
        for _ in 0..<80 {
            // The display ID can change while the framebuffer reconfigures, so re-resolve it.
            if let current = uuid.flatMap(displayID(uuid:)) ?? Optional(id), rotation(current) == degrees { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        throw DisplayError.message("화면 방향을 바꾸지 못했습니다.")
    }

    static func onlineIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Mirrored displays have no NSScreen, so names seen earlier are remembered by UUID.
    @MainActor private static var names: [String: String] = [:]

    @MainActor static func displays() -> [ConnectedDisplay] {
        let links = physicalLinks()
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber, let uuid = uuid(n.uint32Value) {
                names[uuid] = screen.localizedName
            }
        }
        return onlineIDs().compactMap { id in
            guard let active = CGDisplayCopyDisplayMode(id), let uuid = uuid(id) else { return nil }
            let identity = identity(id)
            let candidates = links.filter { $0.identity.vendor == identity.vendor && $0.identity.product == identity.product }
            let link = candidates.first { $0.identity.serial == identity.serial } ?? (candidates.count == 1 ? candidates.first : nil)
            let isBuiltin = CGDisplayIsBuiltin(id) != 0
            let master = CGDisplayMirrorsDisplay(id)
            let name = names[uuid] ?? link?.name ?? (isBuiltin ? "내장 디스플레이" : "모니터 \(identity.modelKey)")
            return ConnectedDisplay(
                id: id, uuid: uuid, identity: identity, name: name,
                isBuiltin: isBuiltin, isMain: CGDisplayIsMain(id) != 0,
                isMirrored: CGDisplayIsInMirrorSet(id) != 0,
                active: DisplayMode(active), modes: DisplayMode.distinct(modes(id).map(DisplayMode.init)),
                signal: link?.signal, nativeWidth: link?.nativeWidth ?? 0, nativeHeight: link?.nativeHeight ?? 0,
                bounds: CGDisplayBounds(id), mirrorOf: master == kCGNullDirectDisplay ? nil : master,
                supportsHDR: supportsHDR(id), hdrEnabled: isHDREnabled(id),
                canRotate: canRotate(id), rotation: rotation(id)
            )
        }.sorted {
            if $0.isMain != $1.isMain { return $0.isMain }
            return ($0.bounds.minX, $0.bounds.minY) < ($1.bounds.minX, $1.bounds.minY)
        }
    }

    /// Applies origins (and mirror sets when `mirroring`) in one transaction, then requested modes.
    static func applyLayout(_ entries: [LayoutEntry], permanent: Bool, mirroring: Bool) throws {
        let ids = Dictionary(entries.compactMap { e in displayID(uuid: e.uuid).map { (e.uuid, $0) } }, uniquingKeysWith: { a, _ in a })
        guard !ids.isEmpty else { throw DisplayError.message("모니터를 찾지 못했습니다. 연결 상태를 확인해 주세요.") }
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
            throw DisplayError.message("디스플레이 설정을 시작하지 못했습니다.")
        }
        for entry in entries {
            guard let id = ids[entry.uuid] else { continue }
            let master = entry.mirrorOf.flatMap { ids[$0] } ?? kCGNullDirectDisplay
            if mirroring {
                let result = CGConfigureDisplayMirrorOfDisplay(configuration, id, master)
                guard result == .success else {
                    CGCancelDisplayConfiguration(configuration)
                    throw DisplayError.message("미러링 설정을 바꾸지 못했습니다. (오류 \(result.rawValue))")
                }
            }
            if master == kCGNullDirectDisplay, let origin = entry.origin {
                let result = CGConfigureDisplayOrigin(configuration, id, Int32(origin.x.rounded()), Int32(origin.y.rounded()))
                guard result == .success else {
                    CGCancelDisplayConfiguration(configuration)
                    throw DisplayError.message("모니터 위치를 바꾸지 못했습니다. (오류 \(result.rawValue))")
                }
            }
        }
        let result = CGCompleteDisplayConfiguration(configuration, permanent ? .permanently : .forSession)
        guard result == .success else { throw DisplayError.message("배치를 적용하지 못했습니다. (오류 \(result.rawValue))") }
        // Mirroring may change modes; restoring them is best effort once the mirror sets are settled.
        for entry in entries {
            guard let modeID = entry.modeID, let id = ids[entry.uuid],
                  CGDisplayCopyDisplayMode(id)?.ioDisplayModeID != modeID else { continue }
            try? configure(id: id, modeID: modeID, permanent: permanent)
        }
    }

    private struct Link {
        let identity: DisplayIdentity
        let name: String?
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
                               name: product["ProductName"] as? String,
                               signal: .init(width: width.intValue, height: height.intValue, refreshRate: hz),
                               nativeWidth: native?.0 ?? 0, nativeHeight: native?.1 ?? 0))
        }
        return result
    }
}
