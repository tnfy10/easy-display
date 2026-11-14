import AppKit
import CryptoKit
import Foundation

struct ReleaseInfo: Equatable {
    let version: String
    let tag: String
    let notes: String
    let page: URL
    let asset: URL
    /// GitHub's "sha256:<hex>" asset digest, when the API provides one.
    let digest: String?
}

enum SemanticVersion {
    /// Compares dotted numeric versions ("v0.10.0" > "0.9.3"); missing parts count as zero.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func parts(_ version: String) -> [Int] {
        let trimmed = version.hasPrefix("v") || version.hasPrefix("V") ? String(version.dropFirst()) : version
        // Ignore pre-release/build suffixes such as "1.2.0-beta".
        let core = trimmed.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }
}

/// Checks GitHub Releases and replaces the running app bundle with the newest build.
@MainActor final class Updater: ObservableObject {
    enum Phase: Equatable { case idle, checking, downloading, installing }

    nonisolated static let repository = "tnfy10/easy-display"
    nonisolated static let bundleName = "Easy Display.app"

    @Published var available: ReleaseInfo?
    @Published var phase: Phase = .idle
    @Published var message: String?
    @Published var autoCheck: Bool { didSet { defaults.set(autoCheck, forKey: "autoCheckUpdates"); schedule() } }
    @Published var autoInstall: Bool { didSet { defaults.set(autoInstall, forKey: "autoInstallUpdates") } }
    /// Set by the display controller so an update never interrupts a pending display change.
    var canInstallNow: () -> Bool = { true }
    private let defaults = UserDefaults.standard
    private var timer: Timer?

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    private var bundleIdentifier: String? { Bundle.main.bundleIdentifier }

    /// Only a writable .app bundle can replace itself (not `swift run`, not a translocated download).
    var canSelfUpdate: Bool {
        let app = Bundle.main.bundleURL
        return app.pathExtension == "app"
            && FileManager.default.isWritableFile(atPath: app.path)
            && FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    init() {
        autoCheck = defaults.object(forKey: "autoCheckUpdates") as? Bool ?? true
        autoInstall = defaults.object(forKey: "autoInstallUpdates") as? Bool ?? true
        schedule()
    }

    private func schedule() {
        timer?.invalidate(); timer = nil
        guard autoCheck, Bundle.main.bundleURL.pathExtension == "app" else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            await self.check(userInitiated: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(userInitiated: false) }
        }
    }

    func check(userInitiated: Bool) async {
        guard phase == .idle else { return }
        phase = .checking
        defer { if phase == .checking { phase = .idle } }
        do {
            let release = try await Self.latestRelease()
            guard SemanticVersion.isNewer(release.version, than: currentVersion) else {
                available = nil
                if userInitiated { message = "최신 버전(\(currentVersion))을 사용 중입니다." }
                return
            }
            available = release
            message = nil
            if autoInstall, !userInitiated, canSelfUpdate, canInstallNow() {
                phase = .idle
                await install()
            }
        } catch {
            if userInitiated { message = "업데이트를 확인하지 못했습니다. \(error.localizedDescription)" }
        }
    }

    func install() async {
        guard phase == .idle, let release = available else { return }
        guard canSelfUpdate else {
            NSWorkspace.shared.open(release.page)
            message = "이 위치에서는 앱을 직접 바꿀 수 없어 릴리스 페이지를 열었습니다. 응용 프로그램 폴더에 옮기면 자동 업데이트를 사용할 수 있어요."
            return
        }
        guard canInstallNow() else { message = "진행 중인 화면 설정 확인을 마친 뒤 업데이트해 주세요."; return }
        do {
            phase = .downloading
            let target = Bundle.main.bundleURL
            let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
            let newApp = try await Self.download(release, into: staging, expectedBundleID: bundleIdentifier)
            phase = .installing
            try Self.launchReplacement(newApp: newApp, target: target, staging: staging)
            NSApp.terminate(nil)
        } catch {
            phase = .idle
            message = "업데이트를 설치하지 못했습니다. \(error.localizedDescription)"
        }
    }

    // MARK: - Steps (off the main actor)

    nonisolated static func latestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("EasyDisplay-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return try parseRelease(data)
        case 404: throw DisplayError.message("릴리스를 찾을 수 없습니다. 저장소가 비공개이거나 아직 릴리스가 없습니다.")
        case 403, 429: throw DisplayError.message("GitHub 요청 한도에 걸렸습니다. 잠시 후 다시 시도해 주세요.")
        default: throw DisplayError.message("GitHub 응답이 올바르지 않습니다.")
        }
    }

    nonisolated static func parseRelease(_ data: Data) throws -> ReleaseInfo {
        struct Asset: Decodable { let name: String; let browser_download_url: URL; let digest: String? }
        struct Release: Decodable {
            let tag_name: String; let body: String?; let html_url: URL
            let draft: Bool?; let prerelease: Bool?; let assets: [Asset]
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard release.draft != true, release.prerelease != true,
              let asset = release.assets.first(where: { $0.name.hasPrefix("Easy-Display-") && $0.name.hasSuffix(".zip") }),
              asset.browser_download_url.host == "github.com" else {
            throw DisplayError.message("릴리스에서 앱 파일을 찾지 못했습니다.")
        }
        let version = SemanticVersion.parts(release.tag_name).map(String.init).joined(separator: ".")
        return ReleaseInfo(version: version, tag: release.tag_name, notes: release.body ?? "", page: release.html_url,
                           asset: asset.browser_download_url, digest: asset.digest)
    }

    /// Downloads and unpacks the ZIP, then checks digest, bundle identity, version, and code signature.
    nonisolated static func download(_ release: ReleaseInfo, into staging: URL, expectedBundleID: String?) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: release.asset)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DisplayError.message("파일을 내려받지 못했습니다.") }
        let zip = staging.appendingPathComponent("update.zip")
        try? FileManager.default.removeItem(at: zip)
        try FileManager.default.moveItem(at: temporary, to: zip)
        if let digest = release.digest, digest.hasPrefix("sha256:") {
            let actual = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
            guard actual == digest.dropFirst("sha256:".count).lowercased() else {
                throw DisplayError.message("내려받은 파일의 체크섬이 일치하지 않습니다.")
            }
        }
        let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
        try? FileManager.default.removeItem(at: extracted)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path])
        let app = extracted.appendingPathComponent(bundleName)
        guard let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == expectedBundleID,
              let version = info["CFBundleShortVersionString"] as? String,
              !SemanticVersion.isNewer(release.version, than: version), !SemanticVersion.isNewer(version, than: release.version) else {
            throw DisplayError.message("내려받은 앱의 정보가 릴리스와 일치하지 않습니다.")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// A detached shell waits for this process to quit, swaps the bundle (restoring it on failure), and relaunches.
    nonisolated static func launchReplacement(newApp: URL, target: URL, staging: URL) throws {
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        backup="$4/previous.app"
        /bin/rm -rf "$backup"
        /bin/mv "$3" "$backup" || exit 1
        if /bin/mv "$2" "$3"; then /bin/rm -rf "$4"; else /bin/mv "$backup" "$3"; fi
        /usr/bin/open "$3"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "easy-display-update", String(ProcessInfo.processInfo.processIdentifier),
                             newApp.path, target.path, staging.path]
        try process.run()
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DisplayError.message("\(URL(fileURLWithPath: tool).lastPathComponent) 검사에 실패했습니다.")
        }
    }
}
