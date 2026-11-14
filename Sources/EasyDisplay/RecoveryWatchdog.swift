import Foundation
import CoreGraphics

/// An independent process survives app termination and reverts unconfirmed previews.
/// The marker contains no instructions; only its existence controls confirmation.
enum RecoveryWatchdog {
    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 5, let modeID = Int32(arguments[3]) else { return 2 }
        let uuid = arguments[2]
        let marker = URL(fileURLWithPath: arguments[4])
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: marker.path) { return 0 }
            Thread.sleep(forTimeInterval: 0.2)
        }
        // Wait briefly for a disconnected screen to reappear, rather than forgetting recovery.
        for _ in 0..<300 {
            if !FileManager.default.fileExists(atPath: marker.path) { return 0 }
            if let id = DisplayHardware.displayID(uuid: uuid) {
                do {
                    try DisplayHardware.configure(id: id, modeID: modeID)
                    try? FileManager.default.removeItem(at: marker)
                    return 0
                } catch { /* Retry while the display reconfigures. */ }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return 1
    }

    /// `--layout-watchdog <marker> <base64 JSON snapshot>`: restores mirror sets and positions.
    static func runLayout(arguments: [String]) -> Int32 {
        guard arguments.count == 4, let data = Data(base64Encoded: arguments[3]),
              let snapshot = try? JSONDecoder().decode([LayoutEntry].self, from: data) else { return 2 }
        let marker = URL(fileURLWithPath: arguments[2])
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: marker.path) { return 0 }
            Thread.sleep(forTimeInterval: 0.2)
        }
        for attempt in 0..<300 {
            if !FileManager.default.fileExists(atPath: marker.path) { return 0 }
            // Wait for every display to come back, but after a minute restore whatever is present.
            let present = snapshot.filter { DisplayHardware.displayID(uuid: $0.uuid) != nil }
            if present.count == snapshot.count || (attempt >= 60 && !present.isEmpty) {
                do {
                    try DisplayHardware.applyLayout(present, permanent: false, mirroring: true)
                    try? FileManager.default.removeItem(at: marker)
                    return 0
                } catch { /* Retry while the displays reconfigure. */ }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return 1
    }

    /// `--hdr-watchdog <marker> <uuid> <0|1>`: restores the previous HDR state.
    static func runHDR(arguments: [String]) -> Int32 {
        guard arguments.count == 5, let original = Int(arguments[4]) else { return 2 }
        let marker = URL(fileURLWithPath: arguments[2])
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: marker.path) { return 0 }
            Thread.sleep(forTimeInterval: 0.2)
        }
        for _ in 0..<300 {
            if !FileManager.default.fileExists(atPath: marker.path) { return 0 }
            if let id = DisplayHardware.displayID(uuid: arguments[3]) {
                do {
                    try DisplayHardware.setHDR(id: id, enabled: original != 0)
                    try? FileManager.default.removeItem(at: marker)
                    return 0
                } catch { /* Retry while the display reconfigures. */ }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return 1
    }

    static func startHDR(uuid: String, originalEnabled: Bool) throws -> URL {
        try launch { ["--hdr-watchdog", $0.path, uuid, originalEnabled ? "1" : "0"] }
    }

    static func start(uuid: String, originalMode: Int32) throws -> URL {
        try launch { ["--watchdog", uuid, String(originalMode), $0.path] }
    }

    static func startLayout(snapshot: [LayoutEntry]) throws -> URL {
        let encoded = try JSONEncoder().encode(snapshot).base64EncodedString()
        return try launch { ["--layout-watchdog", $0.path, encoded] }
    }

    private static func launch(_ arguments: (URL) -> [String]) throws -> URL {
        let directory = OverrideStore.support.appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let marker = directory.appendingPathComponent(UUID().uuidString + ".pending")
        try Data().write(to: marker, options: .atomic)
        let process = Process()
        process.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = arguments(marker)
        do { try process.run() } catch { try? FileManager.default.removeItem(at: marker); throw error }
        return marker
    }
}
