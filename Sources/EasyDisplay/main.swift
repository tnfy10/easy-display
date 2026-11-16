import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The independent watchdog restores any preview even if the app is force-quit.
        .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct EasyDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var controller = DisplayController()
    @StateObject private var updater = Updater()
    @Environment(\.openWindow) private var openWindow

    /// Every timed change confirms in the main window, so it must be on screen first.
    private func show() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        Window("Easy Display", id: "main") {
            ContentView().environmentObject(controller).environmentObject(updater).tint(.mint)
                .onAppear { let controller = controller; updater.canInstallNow = { controller.isIdle } }
        }.defaultSize(width: 1000, height: 780)
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("업데이트 확인…") { Task { await updater.check(userInitiated: true) } }
                        .disabled(updater.phase != .idle)
                }
                CommandGroup(replacing: .newItem) {
                    Button("Easy Display 열기") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut("0", modifiers: .command)
                }
                CommandGroup(after: .toolbar) {
                    Button("모니터 새로고침") {
                        controller.refresh()
                        controller.notice = "모니터 \(controller.displays.count)개를 다시 확인했습니다."
                    }.keyboardShortcut("r", modifiers: .command)
                }
                CommandGroup(replacing: .help) {
                    Button("진단 정보 복사") { controller.copyDiagnostics() }
                    Link("Easy Display 도움말", destination: URL(string: "https://github.com/tnfy10/easy-display#readme")!)
                }
            }
        MenuBarExtra("Easy Display", systemImage: "display.2") {
            Button("Easy Display 열기") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Divider()
            ForEach(controller.stalledPorts) { port in
                Button("⚠︎ \(port.label) 모니터 연결 실패") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            }
            ForEach(controller.displays) { display in
                Menu("\(display.name) · \(display.active.sizeLabel)\(display.active.isHiDPI ? " HiDPI" : "")") {
                    Button("설정 열기…") { show(); controller.open(display) }
                    if let source = controller.display(display.mirrorOf) {
                        Text("\(source.name) 화면을 복제하는 중")
                    } else {
                        Divider()
                        let sizes = controller.scaledResolutions(for: display)
                        if !sizes.isEmpty && !display.isMirrored {
                            Section("화면 크기 (텍스트 크게 → 공간 넓게)") {
                                ForEach(sizes) { mode in
                                    Toggle(mode.sizeLabel, isOn: Binding(
                                        get: { mode.resolutionKey == display.active.resolutionKey },
                                        set: { _ in show(); controller.quickApply(mode, on: display) }))
                                }
                            }
                        }
                        if display.canRotate {
                            Button(display.isPortrait ? "가로로 전환" : "세로로 전환") {
                                show(); controller.setRotation(display, to: display.isPortrait ? .standard : .clockwise)
                            }
                        }
                        let rgb = display.colorModes.filter { $0.isRGB && $0.isHDR == (display.colorMode?.isHDR ?? false) }
                        if Set(rgb.map(\.isFullRange)).count == 2 {
                            Section("RGB 범위") {
                                ForEach([true, false], id: \.self) { full in
                                    Toggle(full ? "Full (0–255)" : "Limited (16–235)", isOn: Binding(
                                        get: { display.colorMode.map { $0.isRGB && $0.isFullRange == full } ?? false },
                                        set: { _ in show(); controller.setRGBRange(display, fullRange: full) }))
                                }
                            }
                        }
                        if display.supportsHDR {
                            Toggle("HDR", isOn: Binding(get: { display.hdrEnabled },
                                                        set: { show(); controller.setHDR(display, enabled: $0) }))
                        }
                    }
                }.disabled(!controller.isIdle)
            }
            if controller.displays.count > 1 {
                Divider()
                Button(controller.isMirroring ? "모든 모니터 확장" : "모든 모니터 미러링") {
                    show()
                    controller.setMirroring(!controller.isMirroring)
                }.disabled(!controller.isIdle)
            }
            Divider()
            if let release = updater.available {
                Button("업데이트 설치 (v\(release.version))") { Task { await updater.install() } }.disabled(updater.phase != .idle)
            } else {
                Button("업데이트 확인") {
                    openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
                    Task { await updater.check(userInitiated: true) }
                }.disabled(updater.phase != .idle)
            }
            Button("모니터 새로고침") { controller.refresh() }
            Button("종료") { controller.rollback(); controller.revertLayout(); NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
        }
        Settings {
            UpdateSettingsView().environmentObject(updater).tint(.mint)
        }
    }
}

if CommandLine.arguments.dropFirst().first == "--watchdog" {
    exit(RecoveryWatchdog.run(arguments: CommandLine.arguments))
} else if CommandLine.arguments.dropFirst().first == "--layout-watchdog" {
    exit(RecoveryWatchdog.runLayout(arguments: CommandLine.arguments))
} else if CommandLine.arguments.dropFirst().first == "--hdr-watchdog" {
    exit(RecoveryWatchdog.runHDR(arguments: CommandLine.arguments))
} else if CommandLine.arguments.dropFirst().first == "--rotation-watchdog" {
    exit(RecoveryWatchdog.runRotation(arguments: CommandLine.arguments))
} else if CommandLine.arguments.dropFirst().first == "--color-watchdog" {
    exit(RecoveryWatchdog.runColorMode(arguments: CommandLine.arguments))
} else if CommandLine.arguments.dropFirst().first == "--diagnose" {
    MainActor.assumeIsolated {
        let controller = DisplayController()
        print(controller.diagnosticText)
    }
} else {
    EasyDisplayApp.main()
}
