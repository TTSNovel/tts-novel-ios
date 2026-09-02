import Foundation

@MainActor
public final class SessionStore: ObservableObject {
    public static let shared = SessionStore()

    // Only one deployment exists — no reason to make the user type a server
    // URL they'll never change. Comes from Config.xcconfig (gitignored, see
    // Config.xcconfig.example) via Info.plist, not committed as a literal.
    public static let baseURL: URL = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SERVER_BASE_URL") as? String,
              !raw.isEmpty, let url = URL(string: raw) else {
            fatalError("SERVER_BASE_URL missing from Info.plist — copy Config.xcconfig.example to Config.xcconfig and fill in your deployment's URL")
        }
        return url
    }()

    @Published public private(set) var isLoggedIn = false
    @Published public private(set) var isRestoring = true
    /// True when isLoggedIn was granted from cached Keychain credentials
    /// without actually reaching the server this launch (offline restore)
    /// — callers use this to skip server-dependent work that would just
    /// fail (see WebnovelReaderApp's progress refresh).
    @Published public private(set) var isOfflineSession = false
    @Published public var loginError: String?

    private init() {}

    /// Called once at launch. The session cookie from a previous run may
    /// have expired (or the app's data may have been reset) even though
    /// Keychain still has the password — re-login against the server
    /// rather than optimistically trusting stale local state. But if the
    /// login attempt fails purely because there's no network, that's not
    /// a reason to log the user out — Keychain only ever holds credentials
    /// saved after a *previous successful* login, so let them back into
    /// their downloaded library instead of dead-ending at LoginView with
    /// no way to fix it offline anyway.
    public func restoreSession() async {
        defer { isRestoring = false }
        guard let creds = Keychain.loadCredentials() else { return }
        do {
            try await APIClient.shared.login(baseURL: Self.baseURL, username: creds.username, password: creds.password)
            isLoggedIn = true
            isOfflineSession = false
        } catch {
            if NetworkMonitor.isNetworkError(error) {
                isLoggedIn = true
                isOfflineSession = true
                EventLogStore.shared.record(.auth, "Khôi phục phiên offline")
            } else {
                isLoggedIn = false
            }
        }
    }

    public func login(username: String, password: String) async {
        loginError = nil
        do {
            try await APIClient.shared.login(baseURL: Self.baseURL, username: username, password: password)
            Keychain.saveCredentials(username: username, password: password)
            isLoggedIn = true
            isOfflineSession = false
            EventLogStore.shared.record(.auth, "Đăng nhập")
        } catch {
            loginError = NetworkMonitor.isNetworkError(error)
                ? "Không có kết nối mạng — vui lòng thử lại"
                : "Đăng nhập thất bại — kiểm tra tài khoản/mật khẩu"
            EventLogStore.shared.record(.error, "Đăng nhập thất bại", detail: loginError)
        }
    }

    /// The credentials behind the current session, if any — used only to
    /// hand a logged-in iPhone's session off to the paired Watch app over
    /// WatchConnectivity (see WebnovelReader/App's WCSession relay and
    /// WebnovelReaderWatch's receiver), which then calls `login(username:
    /// password:)` locally with these same values rather than trying to
    /// share a session cookie directly. Keeps `Keychain` itself fully
    /// internal to Core — this is the one sanctioned way to get a
    /// credential out of it.
    public func credentialsForWatchHandoff() -> (username: String, password: String)? {
        guard let creds = Keychain.loadCredentials() else { return nil }
        return (creds.username, creds.password)
    }

    public func logout() {
        isLoggedIn = false
        isOfflineSession = false
        Keychain.deleteCredentials()
        if let cookies = HTTPCookieStorage.shared.cookies(for: Self.baseURL) {
            cookies.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        }
        EventLogStore.shared.record(.auth, "Đăng xuất")
    }
}
