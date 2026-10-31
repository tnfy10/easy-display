import Foundation
import CryptoKit

struct OverrideBackup: Codable {
    let original: Data?
    let installedHash: String
    let identity: DisplayIdentity
}

/// Only writes one vendor/product file. Existing keys and scale entries are preserved.
enum OverrideStore {
    static let root = URL(fileURLWithPath: "/Library/Displays/Contents/Resources/Overrides", isDirectory: true)
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EasyDisplay", isDirectory: true)
    }
    static func target(_ identity: DisplayIdentity) -> URL {
        root.appendingPathComponent(String(format: "DisplayVendorID-%x", identity.vendor), isDirectory: true)
            .appendingPathComponent(String(format: "DisplayProductID-%x", identity.product))
    }
    static func backupURL(_ identity: DisplayIdentity) -> URL {
        support.appendingPathComponent("override-\(identity.modelKey).json")
    }
    static func pendingURL(_ identity: DisplayIdentity) -> URL {
        support.appendingPathComponent("pending-\(identity.modelKey).json")
    }
    static func hasBackup(_ identity: DisplayIdentity) -> Bool {
        [backupURL(identity), pendingURL(identity)].contains { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func loadBackup(_ identity: DisplayIdentity, current: Data?) throws -> OverrideBackup? {
        var candidates: [OverrideBackup] = []
        for file in [pendingURL(identity), backupURL(identity)] where FileManager.default.fileExists(atPath: file.path) {
            let backup = try JSONDecoder().decode(OverrideBackup.self, from: Data(contentsOf: file))
            guard backup.identity.vendor == identity.vendor, backup.identity.product == identity.product else {
                throw DisplayError.message("백업의 모니터 식별자가 일치하지 않습니다.")
            }
            candidates.append(backup)
        }
        return candidates.first { $0.installedHash == current.map(digest) } ?? candidates.first
    }
    static func originalForBackup(existing: OverrideBackup?, current: Data?) -> Data? {
        if let existing { return existing.original }
        return current
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func encodedResolution(_ resolution: CustomResolution, extended: Bool) -> Data {
        let words: [UInt32] = [UInt32(resolution.width * 2), UInt32(resolution.height * 2), 1] + (extended ? [0x00200000] : [])
        var data = Data()
        for word in words {
            var big = word.bigEndian
            withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func merged(original: Data?, identity: DisplayIdentity, resolutions: [CustomResolution]) throws -> Data {
        var plist: [String: Any] = [:]
        if let original {
            guard let dictionary = try PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any] else {
                throw DisplayError.message("기존 디스플레이 설정 형식을 읽을 수 없어 변경을 중단했습니다.")
            }
            plist = dictionary
            for (key, expected) in [("DisplayVendorID", identity.vendor), ("DisplayProductID", identity.product)] {
                if let value = plist[key] as? NSNumber, value.uint32Value != expected {
                    throw DisplayError.message("기존 설정의 모니터 식별자가 일치하지 않습니다.")
                }
            }
        }
        if let entries = plist["scale-resolutions"], !(entries is [Data]) {
            throw DisplayError.message("기존 HiDPI 항목의 형식이 달라 변경하지 않았습니다.")
        }
        var entries = plist["scale-resolutions"] as? [Data] ?? []
        for resolution in resolutions {
            for extended in [false, true] {
                let data = encodedResolution(resolution, extended: extended)
                if !entries.contains(data) { entries.append(data) }
            }
        }
        plist["DisplayVendorID"] = identity.vendor
        plist["DisplayProductID"] = identity.product
        plist["scale-resolutions"] = entries
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    static func readCurrent(_ identity: DisplayIdentity) throws -> Data? {
        let url = target(identity)
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw DisplayError.message("설정 경로가 심볼릭 링크여서 변경하지 않았습니다.")
        }
        return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }

    static func install(identity: DisplayIdentity, resolutions: [CustomResolution]) throws {
        let previous = try readCurrent(identity)
        let next = try merged(original: previous, identity: identity, resolutions: resolutions)
        let backupFile = backupURL(identity)
        let existingBackup = try loadBackup(identity, current: previous)
        if let existingBackup, previous.map(digest) != existingBackup.installedHash {
            throw DisplayError.message("다른 도구가 설정 파일을 변경했습니다. 기존 백업을 보호하기 위해 중단했습니다.")
        }
        let backup = OverrideBackup(original: originalForBackup(existing: existingBackup, current: previous), installedHash: digest(next), identity: identity)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        // Save recoverable metadata before starting the privileged mutation.
        let pending = pendingURL(identity)
        try JSONEncoder().encode(backup).write(to: pending, options: .atomic)
        do {
            try privilegedReplace(identity: identity, expected: previous, replacement: next)
            try JSONEncoder().encode(backup).write(to: backupFile, options: .atomic)
            try? FileManager.default.removeItem(at: pending)
        } catch {
            // An authorization cancellation leaves the installed file untouched.
            // If installation did complete but saving metadata failed, retain pending recovery data.
            if (try? readCurrent(identity)).flatMap({ $0 }).map(digest) == digest(next) {
                try? JSONEncoder().encode(backup).write(to: backupFile, options: .atomic)
            }
            throw error
        }
    }

    static func restore(identity: DisplayIdentity) throws {
        let backupFile = backupURL(identity)
        let current = try readCurrent(identity)
        guard let backup = try loadBackup(identity, current: current) else {
            throw DisplayError.message("복원할 백업이 없습니다.")
        }
        guard current.map(digest) == backup.installedHash else {
            throw DisplayError.message("설정 파일이 앱 외부에서 변경돼 자동 복원을 중단했습니다. 백업은 보존됩니다.")
        }
        try privilegedReplace(identity: identity, expected: current, replacement: backup.original)
        for file in [backupFile, pendingURL(identity)] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private static func privilegedReplace(identity: DisplayIdentity, expected: Data?, replacement: Data?) throws {
        let fm = FileManager.default
        // Admin subprocesses cannot necessarily read the user's Documents folder.
        let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("easy-display-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let destination = target(identity)
        let source = temporary.appendingPathComponent("override.plist")
        if let replacement { try replacement.write(to: source, options: .atomic) }
        let path = shellQuote(destination.path)
        var script = "#!/bin/sh\nset -eu\n"
        // Reject a link anywhere in the override path before any privileged write.
        for directory in ["/Library/Displays", "/Library/Displays/Contents", "/Library/Displays/Contents/Resources", root.path, destination.deletingLastPathComponent().path, destination.path] {
            script += "if [ -L \(shellQuote(directory)) ]; then echo '설정 경로가 링크로 변경되었습니다.' >&2; exit 1; fi\n"
        }
        if let expected {
            script += "[ -f \(path) ] || exit 1\n"
            script += "actual=$(/usr/bin/shasum -a 256 \(path) | /usr/bin/awk '{print $1}')\n"
            script += "[ \"$actual\" = \(shellQuote(digest(expected))) ] || { echo '설정 파일이 변경되어 중단했습니다.' >&2; exit 1; }\n"
        } else {
            script += "[ ! -e \(path) ] || { echo '새 설정 파일이 발견되어 중단했습니다.' >&2; exit 1; }\n"
        }
        if replacement != nil {
            let staged = destination.path + ".easy-display-" + UUID().uuidString
            script += "/bin/mkdir -p \(shellQuote(destination.deletingLastPathComponent().path))\n"
            script += "/usr/bin/plutil -lint \(shellQuote(source.path)) >/dev/null\n"
            script += "/usr/bin/install -m 644 -o root -g wheel \(shellQuote(source.path)) \(shellQuote(staged))\n"
            script += "/bin/mv -f \(shellQuote(staged)) \(path)\n"
        } else {
            script += "/bin/rm \(path)\n"
        }
        let scriptFile = temporary.appendingPathComponent("apply.sh")
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \(appleScriptQuote("/bin/sh " + shellQuote(scriptFile.path))) with administrator privileges"]
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: output, encoding: .utf8) ?? "관리자 인증 또는 설정 저장에 실패했습니다."
            throw DisplayError.message(message.contains("-128") ? "관리자 인증을 취소했습니다. 설정은 변경하지 않았습니다." : message)
        }
    }
}
