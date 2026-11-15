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
                    Button("모니터 새로고침") { controller.refresh() }.keyboardShortcut("r", modifiers: .command)
                }
            }
        MenuBarExtra("Easy Display", systemImage: "display.2") {
            Button("Easy Display 열기") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Divider()
            ForEach(controller.stalledPorts) { port in
                Button("⚠︎ \(port.label) 모니터 연결 실패") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            }
            ForEach(controller.displays) { display in
                Button {
                    controller.open(display); openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Text("\(display.name) · \(display.active.sizeLabel)\(display.active.isHiDPI ? " HiDPI" : "")")
                }
            }
            if controller.displays.count > 1 {
                Divider()
                Button(controller.isMirroring ? "모든 모니터 확장" : "모든 모니터 미러링") {
                    openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
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
} else if CommandLine.arguments.dropFirst().first == "--diagnose" {
    MainActor.assumeIsolated {
        let controller = DisplayController()
        print(controller.diagnosticText)
    }
} else {
    EasyDisplayApp.main()
}
