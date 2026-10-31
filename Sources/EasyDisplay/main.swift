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
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Easy Display", id: "main") {
            ContentView().environmentObject(controller).tint(.mint)
        }.defaultSize(width: 1000, height: 780)
            .commands {
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
            ForEach(controller.displays) { display in
                Button {
                    controller.select(display); openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Text("\(display.name) · \(display.active.sizeLabel)\(display.active.isHiDPI ? " HiDPI" : "")")
                }
            }
            Divider()
            Button("모니터 새로고침") { controller.refresh() }
            Button("종료") { controller.rollback(); NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
        }
    }
}

if CommandLine.arguments.dropFirst().first == "--watchdog" {
    exit(RecoveryWatchdog.run(arguments: CommandLine.arguments))
} else if CommandLine.arguments.dropFirst().first == "--diagnose" {
    MainActor.assumeIsolated {
        let controller = DisplayController()
        print(controller.diagnosticText)
    }
} else {
    EasyDisplayApp.main()
}
