import SwiftUI
import AppKit

@main
struct HandheldManagerApp: App {
    @StateObject private var model = AppModel()

    init() {
        if let iconURL = Bundle.main.url(forResource: "HandheldManager", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1120, minHeight: 720)
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.titleBar)
    }
}
