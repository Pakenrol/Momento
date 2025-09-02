import SwiftUI

@main
struct MomentoApp: App {
    @StateObject private var updates = UpdatesManager()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 750, maxWidth: 950, minHeight: 650, maxHeight: 850)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updates.checkForUpdates()
                }
            }
        }
    }
}
