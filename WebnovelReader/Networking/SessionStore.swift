import Foundation

@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    // Only one deployment exists (GCP project tts-pipeline-yl, Cloud Run
    // service "novel-web", asia-southeast1) — no reason to make the user
    // type a server URL they'll never change.
    static let baseURL = URL(string: "https://novel-web-328095478338.asia-southeast1.run.app")!

    @Published private(set) var isLoggedIn = false
    @Published private(set) var isRestoring = true
    /// True when isLoggedIn was granted from cached Keychain credentials
    /// without actually reaching the server this launch (offline restore)
    /// — callers use this to skip server-dependent work that would just
    /// fail (see WebnovelReaderApp's progress refresh).
    @Published private(set) var isOfflineSession = false
    @Published var loginError: String?

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
    func restoreSession() async {
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
            } else {
                isLoggedIn = false
            }
        }
    }

    func login(username: String, password: String) async {
        loginError = nil
        do {
            try await APIClient.shared.login(baseURL: Self.baseURL, username: username, password: password)
            Keychain.saveCredentials(username: username, password: password)
            isLoggedIn = true
            isOfflineSession = false
        } catch {
            loginError = NetworkMonitor.isNetworkError(error)
                ? "Không có kết nối mạng — vui lòng thử lại"
                : "Đăng nhập thất bại — kiểm tra tài khoản/mật khẩu"
        }
    }

    func logout() {
        isLoggedIn = false
        isOfflineSession = false
        Keychain.deleteCredentials()
        if let cookies = HTTPCookieStorage.shared.cookies(for: Self.baseURL) {
            cookies.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        }
    }
}
