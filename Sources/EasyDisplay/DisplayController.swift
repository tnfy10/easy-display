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
    @Published var remainingSeconds = 15
    @Published var busy = false
    @Published var showCustom = false
    @Published var showRestoreConfirmation = false
    @Published var customInput = "1920x1080, 2048x1152, 1680x945"
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
    }

    func select(_ display: ConnectedDisplay) {
        guard pending == nil else { return }
        selectedID = display.id
        selectedModeID = display.modes.first { $0.selectionKey == display.active.selectionKey }?.id
    }

    func preview() {
        refresh()
        guard pending == nil, !busy, let display = selected, let target = selectedMode else { return }
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
            "\(display.name)\nUUID: \(display.uuid)\nModel: \(display.identity.modelKey)\nUI: \(display.active.sizeLabel) \(display.active.isHiDPI ? "HiDPI" : "LoDPI")\nRender: \(display.active.pixelWidth) × \(display.active.pixelHeight)\nSignal: \(display.signal?.label ?? "확인 불가")\nMode rate: \(display.active.frequencyLabel)\nAvailable modes: \(display.modes.count)"
        }.joined(separator: "\n\n")
    }
}
