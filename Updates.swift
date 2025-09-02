import Foundation
import SwiftUI

// Sparkle updater integration (optional at compile time)
// This compiles even if Sparkle is not yet added; when you add Sparkle via Xcode/SPM,
// the Check for Updates… menu item will become functional.

@MainActor
final class UpdatesManager: ObservableObject {
    init() {}
    func checkForUpdates() {
        // Fallback: if Sparkle isn't linked at compile-time, open Releases page
        if let url = URL(string: "https://github.com/Pakenrol/Momento/releases") {
            NSWorkspace.shared.open(url)
        }
    }
}

