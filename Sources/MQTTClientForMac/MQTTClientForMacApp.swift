import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Required when the app is started without an app bundle (swift run)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MQTTClientForMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("MQTT Client For Mac") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 680)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Connect") { model.connect() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Disconnect") { model.disconnect() }
                    .keyboardShortcut("d", modifiers: .command)
            }
        }
    }
}
