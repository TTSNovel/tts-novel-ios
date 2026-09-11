import Foundation

public enum APIError: Error {
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
public final class APIClient: @unchecked Sendable {
    public static let shared = APIClient()

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
    public func login(baseURL: URL, username: String, password: String) async throws {
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

    public func fetchBooks(baseURL: URL) async throws -> [Book] {
        let (data, response) = try await session.data(from: baseURL.appendingPathComponent("books.json"))
        try Self.checkOK(response)
        return try JSONDecoder().decode([Book].self, from: data)
    }

    /// `index` is 0-based, matching the server's own NNNN.html filenames.
    public func fetchChapter(baseURL: URL, bookID: Int, index: Int) async throws -> Chapter {
        let html = try await fetchChapterHTML(baseURL: baseURL, bookID: bookID, index: index)
        return ChapterFragmentParser.parse(html: html, index: index)
    }

    /// Raw fragment, pre-parse — DownloadManager persists this (not the
    /// parsed `Chapter`) so offline books stay re-parseable with whatever
    /// `ChapterFragmentParser` does *now*, instead of freezing in whatever
    /// bugs it had on the day a book was downloaded.
    public func fetchChapterHTML(baseURL: URL, bookID: Int, index: Int) async throws -> String {
        let filename = String(format: "%04d.html", index)
        let url = baseURL.appendingPathComponent("books/\(bookID)/data/\(filename)")
        let (data, response) = try await session.data(from: url)
        try Self.checkOK(response)
        guard let html = String(data: data, encoding: .utf8) else { throw APIError.invalidResponse }
        return html
    }

    /// books/<id>/titles.json — every chapter's title, in reading order,
    /// with no other content (book_renderer.render_chapter_titles in the
    /// tts-webnovel repo). One small request instead of fetching every
    /// chapter's full HTML fragment just to read its title — the only way
    /// to show a real chapter list/picker without that cost for a book
    /// that can run into the thousands of chapters.
    public func fetchChapterTitles(baseURL: URL, bookID: Int) async throws -> [String] {
        let url = baseURL.appendingPathComponent("books/\(bookID)/titles.json")
        let (data, response) = try await session.data(from: url)
        try Self.checkOK(response)
        return try JSONDecoder().decode([String].self, from: data)
    }

    public func fetchCoverData(baseURL: URL, bookID: Int, filename: String) async throws -> Data {
        let url = baseURL.appendingPathComponent("books/\(bookID)/\(filename)")
        let (data, response) = try await session.data(from: url)
        try Self.checkOK(response)
        return data
    }

    /// Same endpoint reader.js calls (site_assets/reader.js:237-241) — the
    /// server proxies this to the real TTS backend server-side (app/
    /// server.py's tts_proxy) so the shared secret never has to live in
    /// this client. Returns raw audio bytes (WAV) ready for AVAudioPlayer.
    public func synthesize(baseURL: URL, text: String, voice: TTSVoice, speed: Double, gwenSpeaker: GwenTTSSpeaker? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tts"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(TTSRequestBody(
            text: text, speed: speed, model: voice.rawValue,
            speaker: voice == .gwenTTS ? gwenSpeaker?.rawValue : nil
        ))
        // gwen_tts's autoregressive decode measured 10-90s per sentence on
        // its Cloud Run GPU service (no fast path yet) — the session's
        // default 60s (URLSessionConfiguration.default) would abort a
        // request the server is still legitimately working on. Every other
        // voice here is near-instant, so this is a per-request override,
        // not a session-wide change (matches reader.js's equivalent
        // per-model timeout bump).
        if voice == .gwenTTS {
            request.timeoutInterval = 200
        }

        let (data, response) = try await session.data(for: request)
        try Self.checkOK(response)
        return data
    }

    /// Server-side counterpart: app/server.py's `/api/progress` routes
    /// (tts-webnovel repo) — not one of reader.js's existing endpoints,
    /// added specifically for cross-device resume.
    public func fetchProgress(baseURL: URL) async throws -> [Int: ReadingProgress] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/progress"))
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try Self.checkOK(response)
        return try JSONDecoder.readingProgress.decode([Int: ReadingProgress].self, from: data)
    }

    /// Server-side counterpart: app/server.py's `/api/bug-report` route
    /// (tts-webnovel repo) — writes the report + attached log entries to
    /// site_dir/bug_reports/ for later review, same shared-bucket pattern
    /// as progress.json.
    public func submitBugReport(
        baseURL: URL, description: String, device: String, osVersion: String, appVersion: String, events: [AppEvent]
    ) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/bug-report"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = BugReportBody(
            description: description, device: device, osVersion: osVersion, appVersion: appVersion,
            events: events.map { BugReportEventBody(timestamp: $0.timestamp, category: $0.category.rawValue, message: $0.message, detail: $0.detail) }
        )
        request.httpBody = try JSONEncoder.readingProgress.encode(body)

        let (_, response) = try await session.data(for: request)
        try Self.checkOK(response)
    }

    public func postProgress(baseURL: URL, bookID: Int, chapterIndex: Int, sentenceIndex: Int) async throws -> ReadingProgress {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/progress"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ProgressRequestBody(bookID: bookID, chapterIndex: chapterIndex, sentenceIndex: sentenceIndex)
        )

        let (data, response) = try await session.data(for: request)
        try Self.checkOK(response)
        return try JSONDecoder.readingProgress.decode(ReadingProgress.self, from: data)
    }

    /// Server-side counterpart: app/server.py's `/api/filter-words` routes
    /// (tts-webnovel repo) — one shared list per account, synced whole-list-
    /// at-once (see `FilterWordsStore`).
    public func fetchFilterWords(baseURL: URL) async throws -> FilterWordSet {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/filter-words"))
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try Self.checkOK(response)
        return try JSONDecoder.readingProgress.decode(FilterWordSet.self, from: data)
    }

    public func postFilterWords(baseURL: URL, rules: [FilterWordRule]) async throws -> FilterWordSet {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/filter-words"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.readingProgress.encode(FilterWordsRequestBody(rules: rules))

        let (data, response) = try await session.data(for: request)
        try Self.checkOK(response)
        return try JSONDecoder.readingProgress.decode(FilterWordSet.self, from: data)
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
    let speaker: String?
}

private struct BugReportBody: Encodable {
    let description: String
    let device: String
    let osVersion: String
    let appVersion: String
    let events: [BugReportEventBody]

    enum CodingKeys: String, CodingKey {
        case description, device, events
        case osVersion = "os_version"
        case appVersion = "app_version"
    }
}

private struct BugReportEventBody: Encodable {
    let timestamp: Date
    let category: String
    let message: String
    let detail: String?
}

private struct ProgressRequestBody: Encodable {
    let bookID: Int
    let chapterIndex: Int
    let sentenceIndex: Int

    enum CodingKeys: String, CodingKey {
        case bookID = "book_id"
        case chapterIndex = "chapter"
        case sentenceIndex = "sentence"
    }
}

private struct FilterWordsRequestBody: Encodable {
    let rules: [FilterWordRule]
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
