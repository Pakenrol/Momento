import SwiftUI

@main
struct MomentoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 750, maxWidth: 950, minHeight: 650, maxHeight: 850)
        }
        .windowResizability(.contentSize)
    }
}
