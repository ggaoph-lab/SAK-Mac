import AppKit
import SwiftUI

@main
struct SAKMacApp: App {
    @State private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("SwitchSwitcher") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
    }
}
