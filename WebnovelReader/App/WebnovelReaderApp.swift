import SwiftUI
import AVFoundation
import Core

@main
struct WebnovelReaderApp: App {
    @StateObject private var session = SessionStore.shared
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var progressStore = ProgressStore.shared
    @StateObject private var network = NetworkMonitor.shared
    @StateObject private var playback = ReaderPlaybackController.shared
    @StateObject private var eventLog = EventLogStore.shared
    // Local copy of playback.lastErrorMessage, captured only when
    // errorEventID actually changes (see ReaderPlaybackController's doc
    // comment on that pair) — driving the alert straight off
    // playback.lastErrorMessage would re-show it every time this Group
    // re-renders for an unrelated reason, since optionals don't have a
    // "was just dismissed" state of their own.
    @State private var alertMessage: String?

    init() {
        #if os(iOS)
        // .playback (not .ambient/.soloAmbient) is what keeps audio going
        // when the screen locks or the app backgrounds — paired with the
        // UIBackgroundModes "audio" entry in Info.plist. Without both,
        // iOS suspends the process a few seconds after backgrounding,
        // same as an ordinary (non-PWA) Safari tab. macOS has no
        // AVAudioSession category to configure — the system audio session
        // there is implicit, nothing to opt into.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // EventLogStore.shared is @MainActor-isolated; init() here isn't
            // guaranteed to already be on that actor, so hop over explicitly
            // rather than assuming — this is also the app's only remaining
            // plain print()-only diagnostic, folded in here so EventLogStore
            // is genuinely the one place the app logs anything.
            let description = error.localizedDescription
            Task { @MainActor in
                EventLogStore.shared.record(.error, "Không thiết lập được AVAudioSession", detail: description)
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if session.isRestoring {
                    ProgressView()
                } else {
                    // Guest mode is the default entry point now — the
                    // server's book catalog/covers/chapters are public (see
                    // _is_public_reading_path in tts-webnovel's server.py),
                    // so LibraryView works whether or not `session` actually
                    // has a valid login. LoginView is reachable from
                    // ReaderSettingsSheet ("Đăng nhập") whenever the user
                    // wants online voices or cross-device progress sync —
                    // it's no longer a gate the user must pass before seeing
                    // anything.
                    LibraryView()
                }
            }
            .environmentObject(session)
            .environmentObject(downloads)
            .environmentObject(progressStore)
            .environmentObject(network)
            .environmentObject(playback)
            .environmentObject(eventLog)
            .task {
                #if os(iOS)
                WatchSessionRelay.shared.activate()
                #endif
                await session.restoreSession()
                if session.isLoggedIn && !session.isOfflineSession {
                    await progressStore.refreshFromServer(baseURL: SessionStore.baseURL)
                }
                #if os(iOS)
                if session.isLoggedIn {
                    WatchSessionRelay.shared.relayCurrentSessionIfNeeded()
                }
                #endif
            }
            #if os(iOS)
            .onChange(of: session.isLoggedIn) { _, isLoggedIn in
                if isLoggedIn {
                    WatchSessionRelay.shared.relayCurrentSessionIfNeeded()
                }
            }
            #endif
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
                // branches — ProgressView/LibraryView — and hit a transient
                // state where the overlay's environment wasn't attached
                // yet). Belt-and-suspenders: attach directly.
                PlaybackBar()
                    .environmentObject(playback)
            }
            .onChange(of: playback.errorEventID) { _, _ in
                alertMessage = playback.lastErrorMessage
            }
            .alert("Lỗi", isPresented: Binding(
                get: { alertMessage != nil },
                set: { isPresented in if !isPresented { alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }
}
