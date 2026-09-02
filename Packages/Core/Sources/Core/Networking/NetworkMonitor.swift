import Foundation
import Network

/// Live connectivity signal (via NWPathMonitor) plus a static classifier for
/// "was this failed request actually a connectivity problem" — the app has
/// no equivalent to this at all today, unlike the web app which leans on
/// navigator.onLine + a real probe fetch (site_assets/sw.js's isOnline()).
/// isConnected drives reactive UI (auto-retry, disabling actions that need
/// network, TTS voice fallback); isNetworkError classifies a request that
/// already failed, which avoids racing the monitor's first callback right
/// after cold launch.
@MainActor
public final class NetworkMonitor: ObservableObject {
    public static let shared = NetworkMonitor()

    @Published public private(set) var isConnected = true

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.isConnected = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }

    public static func isNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]
            .contains(urlError.code)
    }
}
