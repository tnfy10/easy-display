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

    static func start(uuid: String, originalMode: Int32) throws -> URL {
        let directory = OverrideStore.support.appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let marker = directory.appendingPathComponent(UUID().uuidString + ".pending")
        try Data().write(to: marker, options: .atomic)
        let process = Process()
        process.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--watchdog", uuid, String(originalMode), marker.path]
        do { try process.run() } catch { try? FileManager.default.removeItem(at: marker); throw error }
        return marker
    }
}
