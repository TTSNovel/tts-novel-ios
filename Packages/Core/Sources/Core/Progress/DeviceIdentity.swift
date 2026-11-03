import Foundation
#if os(macOS)
import SystemConfiguration
#endif

/// Who is writing reading history — sent as `X-Device-Id`/`X-Device-Name`
/// on every request (see APIClient.perform) so the server can say which
/// device moved a book's position, and so a client can tell its own writes
/// apart from another device's when it pulls positions back
/// (`ProgressReconciler`). Before this the server only had a User-Agent,
/// which is why the 2026-11-03 "chapter 441 → 297" jump took log digging to
/// trace back to a stale Firefox tab.
public enum DeviceIdentity {
    /// Generated once per install and kept in Application Support — not the
    /// Keychain: the server only needs it stable while the app is installed,
    /// and a reinstall showing up as a new device is harmless.
    public static let id: String = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("device-id.json")
        if let saved = StoredJSON.load(String.self, from: url), !saved.isEmpty { return saved }
        let fresh = UUID().uuidString.lowercased()
        StoredJSON.save(fresh, to: url)
        return fresh
    }()

    /// Human label shown next to each history row and in conflict banners
    /// ("iPhone đang ở chương 441"). Computed without UIKit (UIDevice is
    /// main-actor only, and this is read from APIClient's background
    /// requests): the hardware model identifier ("iPhone14,4", "iPad13,1")
    /// is enough to tell an iPhone from an iPad.
    public static let name: String = {
        #if os(watchOS)
        return "Apple Watch"
        #elseif os(macOS)
        let computerName = SCDynamicStoreCopyComputerName(nil, nil) as String?
        return computerName.flatMap { $0.isEmpty ? nil : $0 } ?? "Mac"
        #else
        return modelIdentifier.hasPrefix("iPad") ? "iPad" : "iPhone"
        #endif
    }()

    /// `name` as sent in `X-Device-Name` — percent-encoded UTF-8, which the
    /// server unquotes.
    public static let encodedName: String = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "device"

    #if os(iOS)
    /// The simulator reports the host's architecture as `hw.machine`; the
    /// simulated model is in its environment instead.
    private static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }
    #endif
}
