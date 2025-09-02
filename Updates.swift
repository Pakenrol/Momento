import Foundation
import SwiftUI

// Sparkle updater integration with graceful fallback if not present

#if canImport(Sparkle)
import Sparkle

@MainActor
final class UpdatesManager: ObservableObject {
    let updaterController: SPUStandardUpdaterController

    init() {
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

#else

@MainActor
final class UpdatesManager: ObservableObject {
    init() {}
    func checkForUpdates() {
        if let url = URL(string: "https://github.com/Pakenrol/Momento/releases") {
            NSWorkspace.shared.open(url)
        }
    }
}

#endif
