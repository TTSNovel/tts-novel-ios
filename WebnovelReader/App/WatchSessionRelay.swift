import Foundation
import WatchConnectivity
import Core

/// iPhone side of the watch login handoff (see WebnovelReaderWatch's
/// WatchSessionReceiver for the other end) — whenever `SessionStore`
/// reports a logged-in session, pushes the same username/password the
/// phone itself just used over to the paired Watch via
/// `updateApplicationContext` (survives the Watch app not currently
/// running — delivered the next time it launches/activates its own
/// session, unlike `sendMessage` which needs both sides live). Chose
/// credential handoff (Watch calls `SessionStore.login` itself) over
/// trying to share the phone's session cookie directly — `SessionStore`
/// already knows how to turn credentials into a session, no new state
/// machine needed on either end.
@MainActor
final class WatchSessionRelay: NSObject, WCSessionDelegate {
    static let shared = WatchSessionRelay()

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Called from WebnovelReaderApp whenever `session.isLoggedIn` becomes
    /// true (both a fresh login and a restored one) — cheap enough to call
    /// on every transition since `updateApplicationContext` just replaces
    /// whatever context was previously queued, no accumulation.
    func relayCurrentSessionIfNeeded() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        guard let creds = SessionStore.shared.credentialsForWatchHandoff() else { return }
        try? WCSession.default.updateApplicationContext([
            "username": creds.username,
            "password": creds.password,
        ])
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.relayCurrentSessionIfNeeded()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
