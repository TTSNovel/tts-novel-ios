import Foundation

/// One entry in EventLogStore — doubles as both "action history" (what the
/// user did, and when) and "debug log" (what went wrong) per the decision
/// to keep a single unified timeline rather than two separate stores: a bug
/// report is most useful when it shows the errors *in context* of the
/// actions that led to them.
public enum AppEventCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case navigation
    case playback
    case download
    case auth
    case translation
    case error

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .navigation: return "Điều hướng"
        case .playback: return "Phát audio"
        case .download: return "Tải xuống"
        case .auth: return "Đăng nhập"
        case .translation: return "Dịch chương"
        case .error: return "Lỗi"
        }
    }

    public var systemImage: String {
        switch self {
        case .navigation: return "arrow.right.circle"
        case .playback: return "waveform"
        case .download: return "arrow.down.circle"
        case .auth: return "person.circle"
        case .translation: return "globe"
        case .error: return "exclamationmark.triangle"
        }
    }
}

public struct AppEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let category: AppEventCategory
    public let message: String
    public let detail: String?

    public init(category: AppEventCategory, message: String, detail: String? = nil) {
        id = UUID()
        timestamp = Date()
        self.category = category
        self.message = message
        self.detail = detail
    }
}
