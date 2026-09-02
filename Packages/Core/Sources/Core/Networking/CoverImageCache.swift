import CryptoKit
import Foundation

/// Memory+disk cache for remote cover images — AsyncImage has no persistent
/// cache of its own, so without this every list scroll/reappear (CoverImage.swift)
/// re-downloaded the same cover from the server. Disk copies live under
/// Caches/ (not Application Support, where DownloadManager keeps offline
/// books), so the system is free to purge them under storage pressure.
public actor CoverImageCache {
    public static let shared = CoverImageCache()

    private let memory = NSCache<NSURL, NSData>()
    private let fileManager = FileManager.default
    private let directory: URL

    private init() {
        directory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoverImages", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func data(for url: URL) async -> Data? {
        if let cached = memory.object(forKey: url as NSURL) {
            return cached as Data
        }

        let file = diskURL(for: url)
        if let onDisk = try? Data(contentsOf: file) {
            memory.setObject(onDisk as NSData, forKey: url as NSURL)
            return onDisk
        }

        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        memory.setObject(data as NSData, forKey: url as NSURL)
        try? data.write(to: file)
        return data
    }

    private func diskURL(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash)
    }
}
