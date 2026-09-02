import Foundation

// Matches site/books.json entries exactly (app/build_library.py:156-159 in
// the tts-webnovel repo) — `cover` is a filename relative to
// books/<id>/, not a full URL, since the app talks to whatever server the
// user configures in LoginView rather than a fixed host.
public struct Book: Identifiable, Codable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let author: String?
    public let category: String
    public let n: Int
    public let cover: String?

    public init(id: Int, title: String, author: String?, category: String, n: Int, cover: String?) {
        self.id = id
        self.title = title
        self.author = author
        self.category = category
        self.n = n
        self.cover = cover
    }

    public func coverURL(baseURL: URL) -> URL? {
        guard let cover else { return nil }
        return baseURL.appendingPathComponent("books/\(id)/\(cover)")
    }
}

// Parsed from a books/<id>/data/NNNN.html fragment (render_chapter_fragment
// in book_renderer.py: "<h1>{title}</h1>\n{body}") — `index` is 0-based,
// matching the server's own chapter numbering/filenames.
public struct Chapter: Identifiable, Codable, Hashable, Sendable {
    public let index: Int
    public let title: String
    public let text: String

    public init(index: Int, title: String, text: String) {
        self.index = index
        self.title = title
        self.text = text
    }

    public var id: Int { index }
}
