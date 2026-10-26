import Foundation

/// The on-device runtime log `Log` writes to: append-only JSONL files in
/// Application Support/Diagnostics, rotated by size.
///
/// - `app.jsonl`: every entry, all levels — the full timeline.
/// - `errors.jsonl`: error/fault only, so a burst of routine entries can
///   never push the one error that matters out of the log.
///
/// Writes go through one serial queue (callable from any thread or actor);
/// `flush()` blocks until they're on disk, for the crash handler.
public final class DiagnosticsLog: @unchecked Sendable {
    public static let shared = DiagnosticsLog()

    public let directory: URL

    private let queue = DispatchQueue(label: "dev.yanglong.webnovelreader.diagnostics", qos: .utility)
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601WithFractionalSeconds
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private var app: RotatingFile
    private var errors: RotatingFile

    private init() {
        // `swift test` runs unsandboxed — keep its logs out of the real
        // ~/Library/Application Support.
        let isTesting = NSClassFromString("XCTestCase") != nil
        let base = isTesting
            ? FileManager.default.temporaryDirectory.appendingPathComponent("CoreTests-\(UUID().uuidString)")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) // nolog: the logger itself; a failure surfaces as RotatingFile writes failing below
        app = RotatingFile(url: directory.appendingPathComponent("app.jsonl"), maxBytes: 4_000_000, generations: 5)
        errors = RotatingFile(url: directory.appendingPathComponent("errors.jsonl"), maxBytes: 2_000_000, generations: 5)
    }

    func append(_ entry: LogEntry) {
        queue.async { [self] in
            guard var line = try? encoder.encode(entry) else { return } // nolog: can't log a failure to log
            line.append(0x0A)
            app.write(line)
            if entry.level.isError { errors.write(line) }
        }
    }

    /// Blocks until every queued entry is written.
    public func flush() {
        queue.sync {}
    }

    /// Entries at or after `since`, oldest first — errors from `errors.jsonl`
    /// (which outlives `app.jsonl`'s window), everything else from `app.jsonl`.
    public func entries(since: Date, errorsOnly: Bool = false) -> [LogEntry] {
        flush()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        let files = errorsOnly ? errors.allFiles() : app.allFiles()
        var result: [LogEntry] = []
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue } // nolog: rotated generation may not exist
            for line in data.split(separator: 0x0A) {
                guard let entry = try? decoder.decode(LogEntry.self, from: Data(line)) else { continue } // nolog: a torn last line after a crash is expected
                if entry.time >= since { result.append(entry) }
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    /// Every log file, for sharing/exporting as-is.
    public func allFiles() -> [URL] {
        flush()
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] // nolog: empty directory is fine
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Every log file (and stored MetricKit payload) concatenated into one
    /// temporary file to share — each section headed by its file name.
    public func exportFile() -> URL? {
        let stamp = Date().formatted(timestampStyle).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("novel-reader-diagnostics-\(stamp).txt")
        var combined = Data()
        for file in allFiles() {
            guard let data = try? Data(contentsOf: file), !data.isEmpty else { continue } // nolog: rotated generation may be gone
            combined.append(Data("# \(file.lastPathComponent)\n".utf8))
            combined.append(data)
            if data.last != 0x0A { combined.append(0x0A) }
        }
        return Log.attempt(.storage, "Can't write the diagnostics export") {
            try combined.write(to: url, options: .atomic)
            return url
        }
    }

    /// Writes `data` as its own file next to the logs (MetricKit payloads).
    public func store(_ data: Data, named name: String) {
        queue.async { [directory] in
            let url = directory.appendingPathComponent(name)
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                Log.error(.storage, "Can't write a diagnostics file", error: error, ["file": name])
            }
        }
    }

    public func clear() {
        queue.sync {
            app.removeAll()
            errors.removeAll()
        }
    }
}

/// `url` plus `url.1` … `url.(generations-1)`; the current file rolls over
/// to `.1` once it passes `maxBytes`, the oldest generation is dropped.
private struct RotatingFile {
    let url: URL
    let maxBytes: UInt64
    let generations: Int
    private var handle: FileHandle?
    private var size: UInt64 = 0

    init(url: URL, maxBytes: UInt64, generations: Int) {
        self.url = url
        self.maxBytes = maxBytes
        self.generations = generations
    }

    mutating func write(_ data: Data) {
        if handle == nil { open() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            size += UInt64(data.count)
        } catch {
            close() // nolog: the logger's own write failing; reopened on the next entry
            return
        }
        if size >= maxBytes { rotate() }
    }

    func allFiles() -> [URL] {
        (1..<generations).reversed().map(generation) + [url]
    }

    mutating func removeAll() {
        close()
        for file in allFiles() { try? FileManager.default.removeItem(at: file) } // nolog: missing generations are fine
    }

    private func generation(_ n: Int) -> URL {
        url.deletingPathExtension().appendingPathExtension("\(n).\(url.pathExtension)")
    }

    private mutating func open() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url) // nolog: the logger itself; nothing to log a failure to
        size = (try? handle?.seekToEnd()) ?? 0 // nolog: see above
    }

    private mutating func close() {
        try? handle?.close() // nolog: closing a log file; nothing to recover
        handle = nil
        size = 0
    }

    private mutating func rotate() {
        close()
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: generation(generations - 1)) // nolog: oldest generation may not exist
        for n in stride(from: generations - 2, through: 1, by: -1) {
            try? fileManager.moveItem(at: generation(n), to: generation(n + 1)) // nolog: generation may not exist yet
        }
        try? fileManager.moveItem(at: url, to: generation(1)) // nolog: rotation of the logger's own file
    }
}

private let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

private extension JSONEncoder.DateEncodingStrategy {
    static let iso8601WithFractionalSeconds = custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(date.formatted(timestampStyle))
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    static let iso8601WithFractionalSeconds = custom { decoder in
        let container = try decoder.singleValueContainer()
        return try timestampStyle.parse(try container.decode(String.self))
    }
}
