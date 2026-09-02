import SwiftUI
import AVFoundation
import Core

@main
struct WebnovelReaderWatchApp: App {
    @StateObject private var session = SessionStore.shared
    @StateObject private var progressStore = ProgressStore.shared
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var eventLog = EventLogStore.shared
    @StateObject private var playback = WatchPlaybackController.shared

    init() {
        // Same rationale as the iPhone app's AVAudioSession setup
        // (WebnovelReader/App/WebnovelReaderApp.swift) — .playback keeps
        // audio going with the screen off, paired with WKBackgroundModes
        // "audio" in Info.plist.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            let description = error.localizedDescription
            Task { @MainActor in
                EventLogStore.shared.record(.error, "Không thiết lập được AVAudioSession", detail: description)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            WatchLibraryView()
                .environmentObject(session)
                .environmentObject(progressStore)
                .environmentObject(downloads)
                .environmentObject(eventLog)
                .environmentObject(playback)
                .task {
                    // WatchLibraryView's own .task owns restoreSession() +
                    // the initial library fetch — this just wires up the
                    // WCSession login handoff before that runs.
                    WatchSessionReceiver.shared.activate()
                }
        }
    }
}
