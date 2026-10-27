import Combine
import Sparkle
import SwiftUI

/// Sparkle self-update for the builds CI publishes (Scripts/publish-mac.sh).
/// Feed URL and public key come from Info.plist (project.yml). Debug builds
/// never start the updater: their 1.4.0 (1) would always look outdated and
/// an update prompt would get in the way of Xcode runs and UI tests.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    private init() {
        #if DEBUG
        let starts = false
        #else
        let starts = true
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: starts, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// "Check for Updates…" under the app menu's "About" item.
struct CheckForUpdatesCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton(updater: AppUpdater.shared)
        }
    }
}

// A View, not the Commands itself, observes the updater — the layout
// Sparkle's SwiftUI sample uses.
private struct CheckForUpdatesButton: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
