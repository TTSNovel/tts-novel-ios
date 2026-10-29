import Combine
import Core
import Sparkle
import SwiftUI

/// Sparkle self-update for the builds CI publishes (Scripts/publish-mac.sh).
/// Feed URL and public key come from Info.plist (project.yml). Debug builds
/// never start the updater: their 1.4.0 (1) would always look outdated and
/// an update prompt would get in the way of Xcode runs and UI tests.
///
/// Fully automatic: Sparkle checks the appcast every hour
/// (SUScheduledCheckInterval, its minimum), downloads a new build silently
/// (SUAutomaticallyUpdate), and it is
/// installed and relaunched as soon as nothing is playing — not left
/// waiting for a quit the reader may not do for days.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false

    private var controller: SPUStandardUpdaterController!
    private var waitForIdle: AnyCancellable?

    private override init() {
        super.init()
        #if DEBUG
        let starts = false
        #else
        let starts = true
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: starts, updaterDelegate: self, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        // Sparkle calls its delegate on the main thread; the handler isn't
        // annotated Sendable but is only ever invoked there.
        nonisolated(unsafe) let install = immediateInstallHandler
        MainActor.assumeIsolated {
            installWhenIdle(item: item, install: install)
        }
        return true
    }

    /// Relaunching mid-chapter would cut the audio off, so wait until the
    /// reader isn't playing.
    private func installWhenIdle(item: SUAppcastItem, install: @escaping () -> Void) {
        waitForIdle = ReaderPlaybackController.shared.$isPlaying
            .filter { !$0 }
            .first()
            .sink { _ in
                Log.notice(.app, "Installing app update", ["version": item.displayVersionString])
                install()
            }
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
