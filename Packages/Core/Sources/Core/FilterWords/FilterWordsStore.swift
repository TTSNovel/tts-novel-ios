import Foundation

/// Local-first store for the reader's "Filter Words" list, same shape as
/// `ProgressStore`: persists to Application Support so it survives
/// relaunches, and syncs with the server on every edit (edits here are rare
/// user-driven actions, unlike per-sentence progress updates, so there's no
/// need to gate pushes on a "milestone").
@MainActor
public final class FilterWordsStore: ObservableObject {
    public static let shared = FilterWordsStore()

    @Published public private(set) var filterSet: FilterWordSet

    private let fileManager = FileManager.default

    private init() {
        if let loaded = Self.loadFromDisk() {
            filterSet = loaded
        } else {
            // First launch ever — persist the seed immediately so it
            // survives relaunch and has something to push on the next
            // syncToServer/login, instead of only existing in memory until
            // the user makes their first edit.
            filterSet = FilterWordSet(rules: DefaultFilterWords.seed, updatedAt: Date())
            persistToDisk()
        }
    }

    public var rules: [FilterWordRule] { filterSet.rules }

    public func add(pattern: String, isRegex: Bool) {
        var updated = filterSet.rules
        updated.append(FilterWordRule(pattern: pattern, isRegex: isRegex))
        apply(rules: updated)
    }

    public func update(_ rule: FilterWordRule) {
        var updated = filterSet.rules
        guard let index = updated.firstIndex(where: { $0.id == rule.id }) else { return }
        updated[index] = rule
        apply(rules: updated)
    }

    public func delete(id: UUID) {
        apply(rules: filterSet.rules.filter { $0.id != id })
    }

    private func apply(rules: [FilterWordRule]) {
        filterSet = FilterWordSet(rules: rules, updatedAt: Date())
        persistToDisk()
        Task { await syncToServer() }
    }

    /// Best-effort — a failed push just means the next edit (or the next
    /// `refreshFromServer` on another device) tries again later; the local
    /// copy is the source of truth for this device regardless.
    public func syncToServer() async {
        // Guest (no login) can't push filter words — /api/filter-words
        // stays behind auth same as /api/progress (see tts-webnovel's
        // server.py).
        guard SessionStore.shared.isLoggedIn else { return }
        do {
            let stored = try await APIClient.shared.postFilterWords(baseURL: SessionStore.baseURL, rules: filterSet.rules)
            filterSet = stored
            persistToDisk()
        } catch {
            // Offline or server hiccup — local state already has this edit,
            // nothing to roll back.
        }
    }

    /// Pulls the server's list and keeps whichever side is newer — this is
    /// what brings in edits made on another device sharing the same login.
    public func refreshFromServer(baseURL: URL) async {
        guard let remote = try? await APIClient.shared.fetchFilterWords(baseURL: baseURL) else { return }
        if remote.updatedAt > filterSet.updatedAt {
            filterSet = remote
            persistToDisk()
        } else if remote.rules.isEmpty, !filterSet.rules.isEmpty {
            // The account has never had a list pushed to it — bootstrap the
            // server with whatever this device already has (typically the
            // seeded defaults from FilterWordsStore.init), so there's
            // something for a second device to pull instead of an empty
            // list winning by virtue of never being written to.
            await syncToServer()
        }
    }

    private func persistToDisk() {
        guard let data = try? JSONEncoder.readingProgress.encode(filterSet) else { return }
        let url = Self.fileURL()
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    private static func loadFromDisk() -> FilterWordSet? {
        guard let data = try? Data(contentsOf: fileURL()) else { return nil }
        return try? JSONDecoder.readingProgress.decode(FilterWordSet.self, from: data)
    }

    private static func fileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("filter_words.json")
    }
}
