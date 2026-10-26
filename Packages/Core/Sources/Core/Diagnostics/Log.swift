import Foundation
import os

/// App-wide diagnostic logging — the runtime log (what the app did and what
/// went wrong, with enough detail to trace a bug from its first
/// occurrence), separate from `EventLogStore`, which stays the user-facing
/// action history.
///
/// Every entry goes to two places:
/// - `os.Logger` (unified logging): Console.app / `log show`, alongside the
///   system frameworks' own logs (Translation, AVFoundation, URLSession…).
/// - `DiagnosticsLog`: rotating JSONL files in Application Support, kept on
///   the device and attached to bug reports — unified logging doesn't
///   persist debug/info and ages everything out on its own schedule.
///
/// Errors are recorded where they cross a boundary (network, translation,
/// TTS, storage, the top of a background task) with the full error — type,
/// domain, code, userInfo, underlying chain — never just
/// `localizedDescription`. `Scripts/lint-error-handling.py` fails the build
/// on a `catch`/`try?` that drops an error without logging it.
public enum Log {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "dev.yanglong.webnovelreader"

    public static func debug(_ category: LogCategory, _ message: String, _ context: [String: String] = [:]) {
        write(.debug, category, message, error: nil, context)
    }

    public static func info(_ category: LogCategory, _ message: String, _ context: [String: String] = [:]) {
        write(.info, category, message, error: nil, context)
    }

    public static func notice(_ category: LogCategory, _ message: String, _ context: [String: String] = [:]) {
        write(.notice, category, message, error: nil, context)
    }

    /// A cancellation (task cancelled, request cancelled) isn't a failure —
    /// it's logged at debug so stopping something never reads as an error.
    public static func error(_ category: LogCategory, _ message: String, error: Error? = nil, _ context: [String: String] = [:]) {
        let level: LogLevel = error.map(isCancellation) == true ? .debug : .error
        write(level, category, message, error: error, context)
    }

    /// Something that should never happen (crash, broken invariant).
    public static func fault(_ category: LogCategory, _ message: String, error: Error? = nil, _ context: [String: String] = [:]) {
        write(.fault, category, message, error: error, context)
    }

    /// `try?` that records why it returned nil.
    @discardableResult
    public static func attempt<T>(
        _ category: LogCategory, _ message: String, _ context: [String: String] = [:], _ body: () throws -> T
    ) -> T? {
        do {
            return try body()
        } catch {
            Log.error(category, message, error: error, context)
            return nil
        }
    }

    /// Async `try?` that records why it returned nil.
    @discardableResult
    public static func attempt<T>(
        _ category: LogCategory, _ message: String, _ context: [String: String] = [:],
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async -> T? {
        do {
            return try await body()
        } catch {
            Log.error(category, message, error: error, context)
            return nil
        }
    }

    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private static func write(_ level: LogLevel, _ category: LogCategory, _ message: String, error: Error?, _ context: [String: String]) {
        let merged = LogContext.current.merging(context) { $1 }
        let entry = LogEntry(
            time: Date(), level: level, category: category, message: message,
            context: merged.isEmpty ? nil : merged, error: error.map { ErrorInfo($0) }
        )
        let logger = Logger(subsystem: subsystem, category: category.rawValue)
        let line = entry.consoleLine
        // `.public`: this is a personal app's own diagnostics — redacted
        // `<private>` values would make the system log useless for tracing.
        switch level {
        case .debug: logger.debug("\(line, privacy: .public)")
        case .info: logger.info("\(line, privacy: .public)")
        case .notice: logger.notice("\(line, privacy: .public)")
        case .error: logger.error("\(line, privacy: .public)")
        case .fault: logger.fault("\(line, privacy: .public)")
        }
        DiagnosticsLog.shared.append(entry)
    }
}

public enum LogLevel: String, Codable, Sendable, CaseIterable {
    case debug, info, notice, error, fault

    var rank: Int { LogLevel.allCases.firstIndex(of: self) ?? 0 }
    public var isError: Bool { rank >= LogLevel.error.rank }
}

public enum LogCategory: String, Codable, Sendable {
    case app, lifecycle, ui, navigation
    case network, auth, sync
    case library, download, storage
    case playback, tts, translation, predownload
    case watch
}

/// Context attached to every entry logged inside `withLogContext` — the
/// MDC of this app: book, chapter, job… set once where an operation
/// starts instead of being repeated on every log call under it.
public enum LogContext {
    @TaskLocal public static var current: [String: String] = [:]
}

public func withLogContext<T>(
    _ values: [String: String],
    isolation: isolated (any Actor)? = #isolation,
    _ operation: () async throws -> T
) async rethrows -> T {
    try await LogContext.$current.withValue(LogContext.current.merging(values) { $1 }, operation: operation)
}

public struct LogEntry: Codable, Sendable {
    public let time: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
    public let context: [String: String]?
    public let error: ErrorInfo?

    public var consoleLine: String {
        var parts = [message]
        if let context, !context.isEmpty {
            parts.append(context.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        if let error { parts.append("error: \(error.summary)") }
        return parts.joined(separator: " | ")
    }
}

/// Everything an `Error` carries, flattened to strings — what
/// `localizedDescription` throws away ("Unable to Translate" says nothing
/// about which error, which code, or what it wrapped).
public struct ErrorInfo: Codable, Sendable {
    public let type: String
    public let description: String
    public let localized: String
    public let domain: String
    public let code: Int
    public let userInfo: [String: String]?
    public let underlying: [ErrorInfo]?

    public init(_ error: Error, depth: Int = 0) {
        let ns = error as NSError
        type = String(reflecting: Swift.type(of: error))
        description = Self.truncated(String(describing: error), 2000)
        localized = ns.localizedDescription
        domain = ns.domain
        code = ns.code
        let info = ns.userInfo
            .filter { $0.key != NSUnderlyingErrorKey && $0.key != "NSMultipleUnderlyingErrorsKey" }
            .mapValues { Self.truncated(String(describing: $0), 500) }
        userInfo = info.isEmpty ? nil : info
        let nested = ns.underlyingErrors
        underlying = depth < 3 && !nested.isEmpty ? nested.map { ErrorInfo($0, depth: depth + 1) } : nil
    }

    public var summary: String {
        var text = "\(type) \(domain)#\(code): \(description)"
        if let underlying, !underlying.isEmpty {
            text += " ← " + underlying.map(\.summary).joined(separator: "; ")
        }
        return text
    }

    private static func truncated(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
