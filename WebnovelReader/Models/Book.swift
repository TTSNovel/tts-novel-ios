import Foundation

// Matches site/books.json entries exactly (app/build_library.py:156-159 in
// the tts-webnovel repo) — `cover` is a filename relative to
// books/<id>/, not a full URL, since the app talks to whatever server the
// user configures in LoginView rather than a fixed host.
struct Book: Identifiable, Codable, Hashable {
    let id: Int
    let title: String
    let author: String?
    let category: String
    let n: Int
    let cover: String?

    func coverURL(baseURL: URL) -> URL? {
        guard let cover else { return nil }
        return baseURL.appendingPathComponent("books/\(id)/\(cover)")
    }
}

// Parsed from a books/<id>/data/NNNN.html fragment (render_chapter_fragment
// in book_renderer.py: "<h1>{title}</h1>\n{body}") — `index` is 0-based,
// matching the server's own chapter numbering/filenames.
struct Chapter: Identifiable, Codable, Hashable {
    let index: Int
    let title: String
    let text: String

    var id: Int { index }
}
