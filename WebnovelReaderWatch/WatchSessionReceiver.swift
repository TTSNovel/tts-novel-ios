import Foundation
import WatchConnectivity
import Core

/// Watch side of the login handoff — see WebnovelReader/App's
/// WatchSessionRelay for the iPhone side and the reasoning (credential
/// handoff, not session-cookie sharing). Applies whatever username/password
/// the phone last sent by just calling `SessionStore.login(username:
/// password:)` locally, the exact same call the phone's own LoginView
/// makes — the Watch ends up with its own independently-obtained session,
/// no shared/synced cookie state to keep consistent across devices.
@MainActor
final class WatchSessionReceiver: NSObject, WCSessionDelegate {
    static let shared = WatchSessionReceiver()

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // `WCSession`/`[String: Any]` aren't Sendable, so the two String values
    // actually needed are pulled out here — still nonisolated, off the main
    // actor — before hopping over, rather than sending the session/context
    // itself across the actor boundary (mirrors AudioPlaybackService's
    // handleInterruptionNotification, same shape of problem).
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let username = session.receivedApplicationContext["username"] as? String
        let password = session.receivedApplicationContext["password"] as? String
        Task { @MainActor in
            self.applyCredentials(username: username, password: password)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let username = applicationContext["username"] as? String
        let password = applicationContext["password"] as? String
        Task { @MainActor in
            self.applyCredentials(username: username, password: password)
        }
    }

    private func applyCredentials(username: String?, password: String?) {
        guard !SessionStore.shared.isLoggedIn, let username, let password else { return }
        Task {
            await SessionStore.shared.login(username: username, password: password)
        }
    }
}
