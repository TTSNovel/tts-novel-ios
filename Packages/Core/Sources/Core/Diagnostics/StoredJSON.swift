import Foundation

/// Reading/writing the app's local JSON files (progress, filter words,
/// downloads, prerendered audio manifests…) with failures logged — the
/// storage boundary. A missing file is normal (nothing saved yet) and
/// returns nil quietly; a file that exists but can't be read or decoded is
/// corrupted state and is logged with its path.
public enum StoredJSON {
    public static func load<T: Decodable>(
        _ type: T.Type, from url: URL, decoder: JSONDecoder = JSONDecoder(), category: LogCategory = .storage
    ) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(type, from: data)
        } catch {
            Log.error(category, "File unreadable", error: error, ["file": url.path, "type": "\(type)"])
            return nil
        }
    }

    @discardableResult
    public static func save<T: Encodable>(
        _ value: T, to url: URL, encoder: JSONEncoder = JSONEncoder(), category: LogCategory = .storage
    ) -> Bool {
        do {
            let data = try encoder.encode(value)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Log.error(category, "File write failed", error: error, ["file": url.path, "type": "\(T.self)"])
            return false
        }
    }

    /// Removing something that may already be gone is fine; anything else
    /// (permissions, a busy file) is logged.
    public static func remove(_ url: URL, category: LogCategory = .storage) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return // nolog: already gone is the goal
        } catch {
            Log.error(category, "File delete failed", error: error, ["file": url.path])
        }
    }
}
