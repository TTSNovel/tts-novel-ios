import SwiftUI
import AVFoundation

@main
struct WebnovelReaderApp: App {
    @StateObject private var session = SessionStore.shared
    @StateObject private var downloads = DownloadManager.shared

    init() {
        // .playback (not .ambient/.soloAmbient) is what keeps audio going
        // when the screen locks or the app backgrounds — paired with the
        // UIBackgroundModes "audio" entry in Info.plist. Without both,
        // iOS suspends the process a few seconds after backgrounding,
        // same as an ordinary (non-PWA) Safari tab.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AVAudioSession setup failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if session.isRestoring {
                    ProgressView()
                } else if session.isLoggedIn {
                    LibraryView()
                } else {
                    LoginView()
                }
            }
            .environmentObject(session)
            .environmentObject(downloads)
            .task { await session.restoreSession() }
        }
    }
}
