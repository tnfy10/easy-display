import AppKit
import SwiftUI

@MainActor final class DisplayController: ObservableObject {
    @Published var displays: [ConnectedDisplay] = []
    @Published var selectedID: CGDirectDisplayID?
    @Published var selectedModeID: Int32?
    @Published var showLoDPI = false
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var pending: Preview?
    @Published var layoutPending: LayoutPreview?
    @Published var remainingSeconds = 15
    @Published var busy = false
    @Published var showCustom = false
    @Published var showRestoreConfirmation = false
    @Published var customInput = "1920x1080, 2048x1152, 1680x945"
    /// Ports where a cable is detected but no monitor link came up.
    @Published private(set) var stalledPorts: [StalledPort] = []
    /// Hidden until that port recovers or is unplugged.
    @Published private var dismissedPorts: Set<String> = []
    private var portTracker = PortLinkTracker()
    private var timer: Timer?
    private var refreshTimer: Timer?

    struct Preview {
        let uuid: String
        let originalMode: Int32
        let targetMode: Int32
        let marker: URL
        let deadline: Date
        let initialSignal: PhysicalSignal?
    }

    /// A change confirmed within 15 seconds or reverted, also by an independent watchdog.
    struct LayoutPreview {
        enum Original {
            case layout([LayoutEntry])
            case hdr(uuid: String, enabled: Bool)
            case rotation(uuid: String, degrees: Int)
        }
        let original: Original
        let marker: URL
        let deadline: Date
        let title: String
        let summary: String
    }

    var selected: ConnectedDisplay? { displays.first { $0.id == selectedID } }
    var selectedMode: DisplayMode? { selected?.modes.first { $0.id == selectedModeID } }
    var availableResolutions: [DisplayMode] {
        selected?.matchingResolutions.filter { showLoDPI || $0.isHiDPI || $0.resolutionKey == selected?.active.resolutionKey } ?? []
    }
    var selectedResolutionKey: String {
        get { selectedMode?.resolutionKey ?? "" }
        set {
            guard let display = selected, let resolution = display.modes.first(where: { $0.resolutionKey == newValue }) else { return }
            let candidates = display.modes.filter { $0.resolutionKey == resolution.resolutionKey }
            selectedModeID = candidates.min { abs($0.refreshRate - display.active.refreshRate) < abs($1.refreshRate - display.active.refreshRate) }?.id
        }
    }
    var frequencies: [DisplayMode] {
        guard let key = selectedMode?.resolutionKey else { return [] }
        return selected?.modes.filter { $0.resolutionKey == key } ?? []
    }

    init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                self?.refresh()
            }
        }
    }

    func refresh() {
        displays = DisplayHardware.displays()
        if !displays.contains(where: { $0.id == selectedID }) { selectedID = displays.first?.id }
        if let display = selected, !display.modes.contains(where: { $0.id == selectedModeID }) {
            selectedModeID = display.modes.first(where: { $0.selectionKey == display.active.selectionKey })?.id
        }
        refreshPorts()
    }

    var visibleStalledPorts: [StalledPort] { stalledPorts.filter { !dismissedPorts.contains($0.id) } }

    func dismissStalledPort(_ port: StalledPort) { dismissedPorts.insert(port.id) }

    private func refreshPorts() {
        // Links legitimately drop while displays sleep; don't count that as a failure.
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            portTracker = PortLinkTracker()
            stalledPorts = []
            return
        }
        let ports = portTracker.update(PortLinkReader.samples())
        dismissedPorts.formIntersection(ports.map(\.id))
        if ports != stalledPorts { stalledPorts = ports }
    }

    func select(_ display: ConnectedDisplay) {
        guard pending == nil, layoutPending == nil else { return }
        selectedID = display.id
        selectedModeID = display.modes.first { $0.selectionKey == display.active.selectionKey }?.id
    }

    func preview() {
        refresh()
        guard pending == nil, layoutPending == nil, !busy, let display = selected, let target = selectedMode else { return }
        guard !display.isMirrored else { errorMessage = "화면 미러링을 해제한 뒤 설정해 주세요."; return }
        do {
            let marker = try RecoveryWatchdog.start(uuid: display.uuid, originalMode: display.active.id)
            pending = Preview(uuid: display.uuid, originalMode: display.active.id, targetMode: target.id,
                              marker: marker, deadline: Date().addingTimeInterval(15), initialSignal: display.signal)
            remainingSeconds = 15
            do { try DisplayHardware.configure(id: display.id, modeID: target.id) }
            catch {
                rollback()
                throw error
            }
            refresh()
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let preview = self.pending else { return }
                    self.remainingSeconds = max(0, Int(ceil(preview.deadline.timeIntervalSinceNow)))
                    if self.remainingSeconds == 0 { self.rollback() }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func keep() {
        guard let preview = pending, let id = DisplayHardware.displayID(uuid: preview.uuid) else { rollback(); return }
        do {
            // Verify the selected mode is still active before writing the permanent preference.
            guard let actual = CGDisplayCopyDisplayMode(id),
                  let requested = DisplayHardware.modes(id).first(where: { $0.ioDisplayModeID == preview.targetMode }),
                  DisplayMode(actual).selectionKey == DisplayMode(requested).selectionKey else {
                throw DisplayError.message("요청한 모드가 유지되지 않아 원래 설정으로 복구합니다.")
            }
            try DisplayHardware.configure(id: id, modeID: preview.targetMode, permanent: true)
            try FileManager.default.removeItem(at: preview.marker)
            finishPreview()
            notice = "디스플레이 설정을 저장했습니다."
        } catch { errorMessage = error.localizedDescription; rollback() }
    }

    func rollback() {
        guard let preview = pending else { return }
        do {
            guard let id = DisplayHardware.displayID(uuid: preview.uuid) else {
                throw DisplayError.message("모니터가 분리되었습니다. 다시 연결되면 복구 프로세스가 재시도합니다.")
            }
            try DisplayHardware.configure(id: id, modeID: preview.originalMode)
            try? FileManager.default.removeItem(at: preview.marker)
            notice = "이전 디스플레이 설정으로 복구했습니다."
        } catch { errorMessage = error.localizedDescription }
        // On failure, leave the marker so the independent watchdog continues recovery.
        finishPreview()
    }

    // MARK: - Multiple displays

    var isIdle: Bool { pending == nil && layoutPending == nil && !busy }
    /// Displays that occupy their own place in the desktop (mirror sources and independent screens).
    var arrangeable: [ConnectedDisplay] { displays.filter { $0.mirrorOf == nil } }
    var isMirroring: Bool { displays.contains { $0.mirrorOf != nil } }
    func mirrors(of display: ConnectedDisplay) -> [ConnectedDisplay] { displays.filter { $0.mirrorOf == display.id } }
    func display(_ id: CGDirectDisplayID?) -> ConnectedDisplay? { displays.first { $0.id == id } }

    private func snapshot() -> [LayoutEntry] {
        displays.map { d in
            LayoutEntry(uuid: d.uuid, origin: d.bounds.origin,
                        mirrorOf: d.mirrorOf.flatMap { m in displays.first { $0.id == m }?.uuid }, modeID: d.active.id)
        }
    }

    /// Positions never change the output signal, so they are saved immediately.
    private func applyOrigins(_ origins: [String: CGPoint], notice message: String) {
        let entries = origins.map { LayoutEntry(uuid: $0.key, origin: $0.value) }
        do {
            try DisplayHardware.applyLayout(entries, permanent: true, mirroring: false)
            notice = message
        } catch { errorMessage = error.localizedDescription }
        refresh()
    }

    func setMain(_ display: ConnectedDisplay) {
        refresh()
        guard isIdle, let display = self.display(display.id), !display.isMain else { return }
        guard display.mirrorOf == nil else { errorMessage = "미러링된 모니터는 주 모니터로 지정할 수 없습니다. 미러링 원본을 선택해 주세요."; return }
        let origins = Dictionary(uniqueKeysWithValues: arrangeable.map { ($0.uuid, $0.bounds.origin) })
        applyOrigins(DisplayArrangement.normalized(origins, main: display.uuid),
                     notice: "\(display.name)을(를) 주 모니터로 설정했습니다. 메뉴 막대와 Dock이 이 모니터로 이동합니다.")
    }

    /// Moves a display by a drag distance in global points, snapping it to the nearest free edge.
    func move(_ display: ConnectedDisplay, by delta: CGSize) {
        guard isIdle, let display = self.display(display.id), display.mirrorOf == nil,
              let main = arrangeable.first(where: \.isMain) ?? arrangeable.first else { return }
        let dropped = display.bounds.offsetBy(dx: delta.width, dy: delta.height)
        let others = arrangeable.filter { $0.id != display.id }.map(\.bounds)
        guard let origin = DisplayArrangement.snap(dropped, others: others) else {
            errorMessage = "이 위치에는 모니터를 놓을 수 없습니다. 다른 모니터의 가장자리에 붙여 주세요."
            return
        }
        guard origin != display.bounds.origin else { return }
        var origins = Dictionary(uniqueKeysWithValues: arrangeable.map { ($0.uuid, $0.bounds.origin) })
        origins[display.uuid] = origin
        applyOrigins(DisplayArrangement.normalized(origins, main: main.uuid), notice: "모니터 배치를 저장했습니다.")
    }

    /// The display others copy; when several sets exist, the one with the most mirrors.
    var mirrorSource: ConnectedDisplay? {
        arrangeable.filter { !mirrors(of: $0).isEmpty }.max { mirrors(of: $0).count < mirrors(of: $1).count }
    }

    /// Any display can become the source, including one that currently mirrors another;
    /// excluding mirrors here left only the current source to choose from.
    func setMirrorSource(_ source: ConnectedDisplay) {
        refresh()
        guard let source = display(source.id),
              mirrorSource?.id != source.id || mirrors(of: source).count != displays.count - 1 else { return }
        previewLayout(DisplayArrangement.mirrorAll(snapshot(), to: source.uuid),
                      summary: "모든 모니터에 \(source.name) 화면을 표시합니다.")
    }

    func setMirroring(_ enabled: Bool) {
        refresh()
        guard enabled != isMirroring, displays.count > 1 else { return }
        if enabled {
            // The main display is the predictable default source; it can be changed afterwards.
            guard let source = arrangeable.first(where: \.isMain) ?? arrangeable.first else { return }
            previewLayout(DisplayArrangement.mirrorAll(snapshot(), to: source.uuid),
                          summary: "모든 모니터에 \(source.name) 화면을 표시합니다.")
        } else {
            previewLayout(DisplayArrangement.extendAll(snapshot()), summary: "모든 모니터를 확장 화면으로 사용합니다.")
        }
    }

    func mirror(_ display: ConnectedDisplay, of source: ConnectedDisplay?) {
        refresh()
        guard display.mirrorOf != source?.id else { return }
        previewLayout(DisplayArrangement.mirroring(snapshot(), display: display.uuid, of: source?.uuid),
                      summary: source.map { "\(display.name)이(가) \($0.name) 화면을 미러링합니다." } ?? "\(display.name)을(를) 확장 화면으로 사용합니다.")
    }

    /// Mirroring can change modes and output signals, so it uses the same timed confirmation as resolution changes.
    private func previewLayout(_ entries: [LayoutEntry], summary: String) {
        guard isIdle else { return }
        let original = snapshot()
        do {
            let marker = try RecoveryWatchdog.startLayout(snapshot: original)
            layoutPending = LayoutPreview(original: .layout(original), marker: marker, deadline: Date().addingTimeInterval(15),
                                          title: "이 모니터 배치를 유지할까요?", summary: summary)
            try startTimedChange { try DisplayHardware.applyLayout(entries, permanent: false, mirroring: true) }
        } catch { errorMessage = error.localizedDescription }
    }

    func setHDR(_ display: ConnectedDisplay, enabled: Bool) {
        refresh()
        guard isIdle, let display = self.display(display.id), display.supportsHDR, display.mirrorOf == nil, display.hdrEnabled != enabled else { return }
        do {
            let marker = try RecoveryWatchdog.startHDR(uuid: display.uuid, originalEnabled: display.hdrEnabled)
            layoutPending = LayoutPreview(original: .hdr(uuid: display.uuid, enabled: display.hdrEnabled), marker: marker,
                                          deadline: Date().addingTimeInterval(15), title: "이 HDR 설정을 유지할까요?",
                                          summary: "\(display.name)에서 HDR을 \(enabled ? "켰습니다" : "껐습니다").")
            try startTimedChange { try DisplayHardware.setHDR(id: display.id, enabled: enabled) }
        } catch { errorMessage = error.localizedDescription }
    }

    func setRotation(_ display: ConnectedDisplay, to rotation: DisplayRotation) {
        refresh()
        guard isIdle, let display = self.display(display.id), display.canRotate, display.mirrorOf == nil,
              display.rotation != rotation.rawValue else { return }
        do {
            let marker = try RecoveryWatchdog.startRotation(uuid: display.uuid, originalDegrees: display.rotation)
            layoutPending = LayoutPreview(original: .rotation(uuid: display.uuid, degrees: display.rotation), marker: marker,
                                          deadline: Date().addingTimeInterval(15), title: "이 화면 방향을 유지할까요?",
                                          summary: "\(display.name)의 화면 방향을 \(rotation.label)(으)로 바꿨습니다.")
            try startTimedChange { try DisplayHardware.setRotation(id: display.id, degrees: rotation.rawValue) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func startTimedChange(_ apply: () throws -> Void) throws {
        remainingSeconds = 15
        do { try apply() }
        catch { revertLayout(); throw error }
        refresh()
        timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let preview = self.layoutPending else { return }
                    self.remainingSeconds = max(0, Int(ceil(preview.deadline.timeIntervalSinceNow)))
                    if self.remainingSeconds == 0 { self.revertLayout() }
                }
            }
    }

    func keepLayout() {
        guard let preview = layoutPending else { return }
        refresh()
        do {
            if case .layout = preview.original {
                var current = snapshot()
                for i in current.indices { current[i].modeID = nil }
                try DisplayHardware.applyLayout(current, permanent: true, mirroring: true)
            }
            // HDR and rotation are stored by macOS as soon as they switch; confirming only stops the watchdog.
            try FileManager.default.removeItem(at: preview.marker)
            finishLayout()
            notice = "설정을 저장했습니다."
        } catch { errorMessage = error.localizedDescription; revertLayout() }
    }

    func revertLayout() {
        guard let preview = layoutPending else { return }
        do {
            switch preview.original {
            case .layout(let snapshot):
                try DisplayHardware.applyLayout(snapshot, permanent: false, mirroring: true)
            case .hdr(let uuid, let enabled):
                guard let id = DisplayHardware.displayID(uuid: uuid) else {
                    throw DisplayError.message("모니터가 분리되었습니다. 다시 연결되면 복구 프로세스가 재시도합니다.")
                }
                try DisplayHardware.setHDR(id: id, enabled: enabled)
            case .rotation(let uuid, let degrees):
                guard let id = DisplayHardware.displayID(uuid: uuid) else {
                    throw DisplayError.message("모니터가 분리되었습니다. 다시 연결되면 복구 프로세스가 재시도합니다.")
                }
                try DisplayHardware.setRotation(id: id, degrees: degrees)
            }
            try? FileManager.default.removeItem(at: preview.marker)
            notice = "이전 설정으로 복구했습니다."
        } catch { errorMessage = error.localizedDescription }
        // On failure, the marker stays so the independent watchdog keeps retrying.
        finishLayout()
    }

    private func finishLayout() {
        timer?.invalidate(); timer = nil
        layoutPending = nil
        refresh()
    }

    private func finishPreview() {
        timer?.invalidate(); timer = nil
        pending = nil
        selectedModeID = nil
        refresh()
    }

    func installCustom() {
        guard !busy, pending == nil, let display = selected, !display.isBuiltin else { return }
        do {
            let resolutions = try CustomResolution.parse(customInput)
            let ratio = display.signal.map { Double($0.width) / Double($0.height) }
            if let ratio, resolutions.contains(where: { abs(Double($0.width) / Double($0.height) - ratio) > 0.025 }) {
                throw DisplayError.message("모니터와 같은 화면 비율의 해상도를 입력해 주세요.")
            }
            busy = true; showCustom = false
            let identity = display.identity
            Task {
                do {
                    try await Task.detached { try OverrideStore.install(identity: identity, resolutions: resolutions) }.value
                    notice = "HiDPI 모드를 등록했습니다. 작업을 저장하고 Mac을 재시동한 뒤 모드를 선택해 주세요."
                } catch { errorMessage = error.localizedDescription }
                busy = false; refresh()
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func restoreOverride() {
        guard !busy, pending == nil, let identity = selected?.identity else { return }
        busy = true
        Task {
            do {
                try await Task.detached { try OverrideStore.restore(identity: identity) }.value
                notice = "Easy Display로 등록하기 전 설정을 복원했습니다. 재시동 후 반영됩니다."
            } catch { errorMessage = error.localizedDescription }
            busy = false; refresh()
        }
    }

    var diagnosticText: String {
        displays.map { display in
            "\(display.name)\nUUID: \(display.uuid)\nModel: \(display.identity.modelKey)\nUI: \(display.active.sizeLabel) \(display.active.isHiDPI ? "HiDPI" : "LoDPI")\nRender: \(display.active.pixelWidth) × \(display.active.pixelHeight)\nSignal: \(display.signal?.label ?? "확인 불가")\nMode rate: \(display.active.frequencyLabel)\nMain: \(display.isMain)\nBounds: \(Int(display.bounds.minX)), \(Int(display.bounds.minY)) \(Int(display.bounds.width)) × \(Int(display.bounds.height))\nMirrors: \(self.display(display.mirrorOf)?.name ?? "-")\nRotation: \(display.rotation)°\(display.canRotate ? "" : " (fixed)")\nHDR: \(display.supportsHDR ? (display.hdrEnabled ? "on" : "off") : "unsupported")\nAvailable modes: \(display.modes.count)"
        }.joined(separator: "\n\n") + portDiagnostics
    }

    private var portDiagnostics: String {
        let samples = PortLinkReader.samples()
        guard !samples.isEmpty else { return "" }
        return "\n\nPorts:\n" + samples.map { s in
            "\(s.portLabel): cable \(s.hotPlug ? "detected" : "none"), monitors \(s.sinkCount)\(s.productName.map { " (\($0))" } ?? "")\(s.isStalled ? " — LINK FAILED" : "")"
        }.joined(separator: "\n")
    }
}
