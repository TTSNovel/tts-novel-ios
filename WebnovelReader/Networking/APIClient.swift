import Foundation

enum APIError: Error {
    case invalidResponse
    case notAuthenticated
    case httpStatus(Int)
}

// Talks to the exact same endpoints site_assets/reader.js and download.js
// use — app/server.py (tts-webnovel repo) has no separate JSON API, it
// just serves the statically-rendered site (books.json, books/<id>/
// meta.json, books/<id>/data/NNNN.html) behind a session-cookie login.
// This client authenticates the same way a browser would (POST /login,
// keep the Set-Cookie) and reads those same static files.
final class APIClient: @unchecked Sendable {
    static let shared = APIClient()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        session = URLSession(configuration: config)
    }

    /// POSTs the login form; on success the session cookie lands in
    /// HTTPCookieStorage.shared and every subsequent request (including
    /// ones made by AsyncImage's own URLSession, which shares that same
    /// cookie storage by default) is authenticated automatically.
    func login(baseURL: URL, username: String, password: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("login"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = "username=\(username.urlFormEncoded)&password=\(password.urlFormEncoded)"
        request.httpBody = Data(form.utf8)

        let (_, response) = try await session.data(for: request)
        // Wrong credentials: server re-renders the login page with 401,
        // no redirect. Right credentials: 302 to `next` (URLSession
        // follows it, converting to GET per standard redirect handling),
        // landing on a 200 page that itself required the new cookie to
        // load — so 200 here already proves the cookie is good.
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.notAuthenticated
        }
    }

    func fetchBooks(baseURL: URL) async throws -> [Book] {
        let (data, response) = try await session.data(from: baseURL.appendingPathComponent("books.json"))
        try Self.checkOK(response)
        return try JSONDecoder().decode([Book].self, from: data)
    }

    /// `index` is 0-based, matching the server's own NNNN.html filenames.
    func fetchChapter(baseURL: URL, bookID: Int, index: Int) async throws -> Chapter {
        let filename = String(format: "%04d.html", index)
        let url = baseURL.appendingPathComponent("books/\(bookID)/data/\(filename)")
        let (data, response) = try await session.data(from: url)
        try Self.checkOK(response)
        guard let html = String(data: data, encoding: .utf8) else { throw APIError.invalidResponse }
        return ChapterFragmentParser.parse(html: html, index: index)
    }

    func fetchCoverData(baseURL: URL, bookID: Int, filename: String) async throws -> Data {
        let url = baseURL.appendingPathComponent("books/\(bookID)/\(filename)")
        let (data, response) = try await session.data(from: url)
        try Self.checkOK(response)
        return data
    }

    /// Same endpoint reader.js calls (site_assets/reader.js:237-241) — the
    /// server proxies this to the real TTS backend server-side (app/
    /// server.py's tts_proxy) so the shared secret never has to live in
    /// this client. Returns raw audio bytes (WAV) ready for AVAudioPlayer.
    func synthesize(baseURL: URL, text: String, voice: TTSVoice, speed: Double) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tts"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(TTSRequestBody(text: text, speed: speed, model: voice.rawValue))

        let (data, response) = try await session.data(for: request)
        try Self.checkOK(response)
        return data
    }

    private static func checkOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.notAuthenticated }
        guard 200..<300 ~= http.statusCode else { throw APIError.httpStatus(http.statusCode) }
    }
}

private struct TTSRequestBody: Encodable {
    let text: String
    let speed: Double
    let model: String
}

private extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? self
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+")
        return set
    }()
}
