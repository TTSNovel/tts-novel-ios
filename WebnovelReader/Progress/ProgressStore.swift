import Foundation

// Local-first reading-position tracker, same shape as DownloadManager:
// persists to Application Support so it survives relaunches, syncs to the
// server only at milestones (ReaderView calls syncToServer on pause/stop/
// chapter-change/app-background) rather than on a timer.
@MainActor
final class ProgressStore: ObservableObject {
    static let shared = ProgressStore()

    @Published private(set) var progress: [Int: ReadingProgress] = [:]

    private let fileManager = FileManager.default

    private init() {
        progress = Self.loadFromDisk()
    }

    func localProgress(bookID: Int) -> ReadingProgress? {
        progress[bookID]
    }

    func mostRecentlyRead() -> (bookID: Int, progress: ReadingProgress)? {
        progress.max { $0.value.updatedAt < $1.value.updatedAt }
            .map { (bookID: $0.key, progress: $0.value) }
    }

    func recordLocal(bookID: Int, chapterIndex: Int, sentenceIndex: Int) {
        progress[bookID] = ReadingProgress(chapterIndex: chapterIndex, sentenceIndex: sentenceIndex, updatedAt: Date())
        persistToDisk()
    }

    /// Best-effort — a failed push just means the next milestone (or the
    /// next refreshFromServer on another device) tries again later; the
    /// local copy is the source of truth for this device regardless.
    func syncToServer(bookID: Int) async {
        guard let entry = progress[bookID] else { return }
        do {
            let stored = try await APIClient.shared.postProgress(
                baseURL: SessionStore.baseURL, bookID: bookID,
                chapterIndex: entry.chapterIndex, sentenceIndex: entry.sentenceIndex
            )
            progress[bookID] = stored
            persistToDisk()
        } catch {
            // Offline or server hiccup — local state already has this
            // progress, nothing to roll back.
        }
    }

    /// Pulls every book's server-side progress and merges by `updatedAt`,
    /// keeping whichever side is newer — this is what brings in progress
    /// made on another device sharing the same login.
    func refreshFromServer(baseURL: URL) async {
        guard let remote = try? await APIClient.shared.fetchProgress(baseURL: baseURL) else { return }
        for (bookID, remoteEntry) in remote {
            if let local = progress[bookID], local.updatedAt >= remoteEntry.updatedAt { continue }
            progress[bookID] = remoteEntry
        }
        persistToDisk()
    }

    private func persistToDisk() {
        guard let data = try? JSONEncoder.readingProgress.encode(progress) else { return }
        let url = Self.fileURL()
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    private static func loadFromDisk() -> [Int: ReadingProgress] {
        guard let data = try? Data(contentsOf: fileURL()),
              let decoded = try? JSONDecoder.readingProgress.decode([Int: ReadingProgress].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func fileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("progress.json")
    }
}
