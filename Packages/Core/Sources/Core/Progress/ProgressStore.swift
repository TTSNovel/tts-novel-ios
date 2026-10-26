import Foundation

// Local-first reading-history tracker, same shape as DownloadManager:
// persists to Application Support so it survives relaunches, syncs to the
// server only at milestones (ReaderView calls syncToServer on pause/stop/
// chapter-change/app-background) rather than on a timer.
//
// History is per chapter: an entry only changes when the reader moves to a
// different chapter. Re-reading the chapter this device already has saved
// is a no-op and pushes nothing — otherwise a device left open on an older
// chapter would overwrite the newer chapter another device pushed since.
@MainActor
public final class ProgressStore: ObservableObject {
    public static let shared = ProgressStore()

    @Published public private(set) var progress: [Int: ReadingProgress] = [:]
    /// Books whose local entry changed since its last successful push —
    /// syncToServer only sends these, so a stale local entry never
    /// overwrites the server.
    private var unsynced: Set<Int> = []

    private init() {
        progress = Self.loadFromDisk()
        unsynced = StoredJSON.load(Set<Int>.self, from: Self.unsyncedFileURL()) ?? []
    }

    public func localProgress(bookID: Int) -> ReadingProgress? {
        progress[bookID]
    }

    public func mostRecentlyRead() -> (bookID: Int, progress: ReadingProgress)? {
        progress.max { $0.value.updatedAt < $1.value.updatedAt }
            .map { (bookID: $0.key, progress: $0.value) }
    }

    /// Every book with saved progress, most-recently-updated first — backs
    /// both the Library's "Đọc gần đây" preview (capped) and the full
    /// History screen (uncapped). `limit: nil` returns everything.
    public func recentEntries(limit: Int? = nil) -> [(bookID: Int, progress: ReadingProgress)] {
        let sorted = progress.sorted { $0.value.updatedAt > $1.value.updatedAt }
            .map { (bookID: $0.key, progress: $0.value) }
        guard let limit else { return sorted }
        return Array(sorted.prefix(limit))
    }

    public func recordLocal(bookID: Int, chapterIndex: Int) {
        guard progress[bookID]?.chapterIndex != chapterIndex else { return }
        progress[bookID] = ReadingProgress(chapterIndex: chapterIndex, updatedAt: Date())
        unsynced.insert(bookID)
        persistToDisk()
    }

    /// Best-effort — a failed push just means the next milestone (or the
    /// next refreshFromServer on another device) tries again later; the
    /// local copy is the source of truth for this device regardless.
    public func syncToServer(bookID: Int) async {
        // Guest (no login) can't push progress — /api/progress stays behind
        // auth (see tts-webnovel's server.py) even though book browsing/
        // reading itself is now public. Checked up front rather than just
        // letting the request 401 into the catch below, to avoid a pointless
        // network round trip on every chapter change while a guest is
        // reading.
        guard SessionStore.shared.isLoggedIn else { return }
        guard unsynced.contains(bookID), let entry = progress[bookID] else { return }
        do {
            let stored = try await APIClient.shared.postProgress(
                baseURL: SessionStore.baseURL, bookID: bookID, chapterIndex: entry.chapterIndex
            )
            // The reader may have moved on while the request was in flight —
            // keep that newer chapter (still unsynced) instead of the reply.
            guard progress[bookID]?.chapterIndex == stored.chapterIndex else { return }
            progress[bookID] = stored
            unsynced.remove(bookID)
            persistToDisk()
        } catch {
            // Offline or server hiccup — local state already has this
            // progress and stays unsynced, nothing to roll back.
            Log.notice(.sync, "Reading progress not pushed to the server", ["book": "\(bookID)", "error": ErrorInfo(error).summary])
        }
    }

    /// Pulls every book's server-side progress and merges by `updatedAt`,
    /// keeping whichever side is newer — this is what brings in progress
    /// made on another device sharing the same login.
    public func refreshFromServer(baseURL: URL) async {
        guard let remote = try? await APIClient.shared.fetchProgress(baseURL: baseURL) else { return } // nolog: APIClient logs the failed request
        for (bookID, remoteEntry) in remote {
            if let local = progress[bookID], local.updatedAt >= remoteEntry.updatedAt { continue }
            progress[bookID] = remoteEntry
            unsynced.remove(bookID)
        }
        persistToDisk()
    }

    private func persistToDisk() {
        StoredJSON.save(progress, to: Self.fileURL(), encoder: .readingProgress)
        StoredJSON.save(unsynced, to: Self.unsyncedFileURL())
    }

    private static func loadFromDisk() -> [Int: ReadingProgress] {
        StoredJSON.load([Int: ReadingProgress].self, from: fileURL(), decoder: .readingProgress) ?? [:]
    }

    private static func fileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("progress.json")
    }

    private static func unsyncedFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("progress-unsynced.json")
    }
}
