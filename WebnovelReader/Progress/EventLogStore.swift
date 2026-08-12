import Foundation

/// App-wide action/debug timeline — same local-first, persist-to-Application-
/// Support shape as ProgressStore/DownloadManager. Every screen and
/// controller that performs a user-visible action or hits an error calls
/// `record`; ActionHistoryView reads it back (optionally filtered) and
/// BugReportView attaches the most recent entries to a submitted report.
@MainActor
final class EventLogStore: ObservableObject {
    static let shared = EventLogStore()

    /// Bounded so a long-running session doesn't grow this file without
    /// limit — oldest entries drop first, same trade-off DownloadManager
    /// makes with disk space. Sized generously (not just a few hundred)
    /// because every auto-advanced sentence during playback logs its own
    /// entry now, not just explicit user actions — a single long chapter
    /// can easily be a few hundred sentences on its own.
    static let maxEntries = 2000

    @Published private(set) var events: [AppEvent] = []

    private let fileManager = FileManager.default

    private init() {
        events = Self.loadFromDisk()
    }

    func record(_ category: AppEventCategory, _ message: String, detail: String? = nil) {
        events.append(AppEvent(category: category, message: message, detail: detail))
        if events.count > Self.maxEntries {
            events.removeFirst(events.count - Self.maxEntries)
        }
        persistToDisk()
    }

    /// Most-recent-first, optionally restricted to a set of categories
    /// (`nil`/empty means no category filter) and/or to entries at or after
    /// `since` (`nil` means no time cutoff) — BugReportView uses `since` to
    /// attach "the recent log," not an arbitrary entry count, since a fixed
    /// count skews short whenever per-sentence playback logging is active.
    func entries(matching categories: Set<AppEventCategory>? = nil, since: Date? = nil) -> [AppEvent] {
        var result = events.sorted { $0.timestamp > $1.timestamp }
        if let categories, !categories.isEmpty {
            result = result.filter { categories.contains($0.category) }
        }
        if let since {
            result = result.filter { $0.timestamp >= since }
        }
        return result
    }

    func clear() {
        events = []
        persistToDisk()
    }

    private func persistToDisk() {
        guard let data = try? JSONEncoder.readingProgress.encode(events) else { return }
        let url = Self.fileURL()
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    private static func loadFromDisk() -> [AppEvent] {
        guard let data = try? Data(contentsOf: fileURL()),
              let decoded = try? JSONDecoder.readingProgress.decode([AppEvent].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func fileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("event_log.json")
    }
}
