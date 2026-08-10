import SwiftUI
import AVFoundation

@main
struct WebnovelReaderApp: App {
    @StateObject private var session = SessionStore.shared
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var progressStore = ProgressStore.shared
    @StateObject private var network = NetworkMonitor.shared
    @StateObject private var playback = ReaderPlaybackController.shared

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
            .environmentObject(progressStore)
            .environmentObject(network)
            .environmentObject(playback)
            .task {
                await session.restoreSession()
                if session.isLoggedIn && !session.isOfflineSession {
                    await progressStore.refreshFromServer(baseURL: SessionStore.baseURL)
                }
            }
            // The one real PlaybackBar instance lives here, as a plain
            // overlay at the window root — not woven into any
            // NavigationStack/List's own safeAreaInset chain (see
            // PlaybackBar's doc comment for why that nesting was tried and
            // reverted: it's what caused the bar's real height, changing
            // conditionally, to feed back into the List's own inset
            // calculations and freeze the whole UI). LibraryView and every
            // pushed screen (BookDetailView/HistoryView/ReaderView/
            // DownloadedBooksView) only reserve a plain, inert
            // Color.clear spacer via their own safeAreaInset — this overlay
            // just sits in that reserved gap, persisting across every
            // screen the same way Music/Podcasts' mini-player does, with no
            // layout feedback path back into any List at all.
            .overlay(alignment: .bottom) {
                // Explicit .environmentObject here too: this overlay's
                // content crashed with a missing-EnvironmentObject trap
                // when it only relied on inheriting the one attached above
                // (SwiftUI's WindowGroup root re-evaluates this Group's
                // branches — ProgressView/LibraryView/LoginView — and hit a
                // transient state where the overlay's environment wasn't
                // attached yet). Belt-and-suspenders: attach directly.
                PlaybackBar()
                    .environmentObject(playback)
            }
        }
    }
}
