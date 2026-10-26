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

        let (_, response) = try await perform(request)
        // Wrong credentials: server re-renders the login page with 401,
        // no redirect. Right credentials: 302 to `next` (URLSession
        // follows it, converting to GET per standard redirect handling),
        // landing on a 200 page that itself required the new cookie to
        // load — so 200 here already proves the cookie is good.
        guard response.statusCode == 200 else {
            Log.notice(.auth, "Login rejected", ["status": "\(response.statusCode)"])
            throw APIError.notAuthenticated
        }
    }

    public func fetchBooks(baseURL: URL) async throws -> [Book] {
        let data = try await send(URLRequest(url: baseURL.appendingPathComponent("books.json")))
        return try Self.decode([Book].self, from: data)
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
        let data = try await send(URLRequest(url: url))
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
        let data = try await send(URLRequest(url: url))
        return try Self.decode([String].self, from: data)
    }

    public func fetchCoverData(baseURL: URL, bookID: Int, filename: String) async throws -> Data {
        let url = baseURL.appendingPathComponent("books/\(bookID)/\(filename)")
        let data = try await send(URLRequest(url: url))
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

        let data = try await send(request)
        return data
    }

    /// Server-side counterpart: app/server.py's `/api/progress` routes
    /// (tts-webnovel repo) — not one of reader.js's existing endpoints,
    /// added specifically for cross-device resume.
    public func fetchProgress(baseURL: URL) async throws -> [Int: ReadingProgress] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/progress"))
        request.httpMethod = "GET"
        let data = try await send(request)
        return try Self.decode([Int: ReadingProgress].self, from: data, decoder: .readingProgress)
    }

    /// Server-side counterpart: app/server.py's `/api/bug-report` route
    /// (tts-webnovel repo) — writes the report + attached log entries to
    /// site_dir/bug_reports/ for later review, same shared-bucket pattern
    /// as progress.json.
    public func submitBugReport(
        baseURL: URL, description: String, device: String, osVersion: String, appVersion: String, events: [AppEvent],
        diagnostics: [LogEntry] = []
    ) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/bug-report"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = BugReportBody(
            description: description, device: device, osVersion: osVersion, appVersion: appVersion,
            // The server stores `events` only, so diagnostic log entries
            // ride along in the same list, tagged `log.<category>`.
            events: diagnostics.map {
                BugReportEventBody(timestamp: $0.time, category: "log.\($0.category.rawValue)", message: "[\($0.level.rawValue)] \($0.message)", detail: $0.consoleLine)
            } + events.map { BugReportEventBody(timestamp: $0.timestamp, category: $0.category.rawValue, message: $0.message, detail: $0.detail) }
        )
        request.httpBody = try JSONEncoder.readingProgress.encode(body)

        _ = try await send(request)
    }

    public func postProgress(baseURL: URL, bookID: Int, chapterIndex: Int) async throws -> ReadingProgress {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/progress"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ProgressRequestBody(bookID: bookID, chapterIndex: chapterIndex)
        )

        let data = try await send(request)
        return try Self.decode(ReadingProgress.self, from: data, decoder: .readingProgress)
    }

    /// Server-side counterpart: app/server.py's `/api/filter-words` routes
    /// (tts-webnovel repo) — one shared list per account, synced whole-list-
    /// at-once (see `FilterWordsStore`).
    public func fetchFilterWords(baseURL: URL) async throws -> FilterWordSet {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/filter-words"))
        request.httpMethod = "GET"
        let data = try await send(request)
        return try Self.decode(FilterWordSet.self, from: data, decoder: .readingProgress)
    }

    public func postFilterWords(baseURL: URL, rules: [FilterWordRule]) async throws -> FilterWordSet {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/filter-words"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.readingProgress.encode(FilterWordsRequestBody(rules: rules))

        let data = try await send(request)
        return try Self.decode(FilterWordSet.self, from: data, decoder: .readingProgress)
    }

    /// Server-side counterpart: app/server.py's `/api/translate` (tts-webnovel
    /// repo) — Google Cloud Translation v3 with the book's glossary. The
    /// server stores every translated segment per chapter, so asking again
    /// for something already translated (by this device, another one, or
    /// the web reader) comes straight back from storage. Returns
    /// translations aligned with `texts`.
    public func translate(
        baseURL: URL, bookID: Int, chapterIndex: Int, texts: [String], source: String, target: String
    ) async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/translate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            TranslateRequestBody(bookID: bookID, chapter: chapterIndex, texts: texts, source: source, target: target)
        )
        let data = try await send(request)
        let translations = try Self.decode(TranslateResponseBody.self, from: data).translations
        guard translations.count == texts.count else { throw APIError.invalidResponse }
        return translations
    }

    /// The whole translation glossary (shared + every book's terms) — see
    /// `GlossaryTerm`.
    public func fetchGlossary(baseURL: URL) async throws -> [GlossaryTerm] {
        let data = try await send(URLRequest(url: baseURL.appendingPathComponent("api/glossary")))
        return try Self.decode(GlossaryBody.self, from: data).terms
    }

    /// Replaces the whole glossary; the server publishes it to Google before
    /// answering (a few seconds per changed glossary). Returns the stored
    /// list. A publish failure comes back as `APIError.httpStatus(502)` with
    /// the list itself already saved.
    public func saveGlossary(baseURL: URL, terms: [GlossaryTerm]) async throws -> [GlossaryTerm] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/glossary"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try JSONEncoder().encode(GlossaryBody(terms: terms))
        let data = try await send(request)
        return try Self.decode(GlossaryBody.self, from: data).terms
    }

    /// How many chapters of `bookID` have translations stored on the server.
    public func fetchStoredTranslationChapterCount(baseURL: URL, bookID: Int) async throws -> Int {
        let data = try await send(URLRequest(url: baseURL.appendingPathComponent("api/translations/\(bookID)")))
        return try Self.decode(StoredTranslationsBody.self, from: data).chapters.count
    }

    /// Deletes every stored translation of `bookID` on the server.
    public func deleteStoredTranslations(baseURL: URL, bookID: Int) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/translations/\(bookID)"))
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    /// The one place every request goes through: tags it with an
    /// `X-Request-ID` (logged here, so a failure can be matched to the
    /// server's own logs) and logs the outcome — transport errors and
    /// non-2xx responses at error level with the start of the response
    /// body, successes at debug with their timing. Request bodies are never
    /// logged (login carries the password).
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        let requestID = String(UUID().uuidString.prefix(8)).lowercased()
        request.setValue(requestID, forHTTPHeaderField: "X-Request-ID")
        var context = [
            "request": requestID,
            "method": request.httpMethod ?? "GET",
            "path": request.url?.path ?? "?",
        ]
        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            context["ms"] = Self.milliseconds(since: started)
            Log.error(.network, "Request failed", error: error, context)
            throw error
        }
        context["ms"] = Self.milliseconds(since: started)
        guard let http = response as? HTTPURLResponse else {
            Log.error(.network, "Response is not HTTP", error: APIError.invalidResponse, context)
            throw APIError.invalidResponse
        }
        context["status"] = "\(http.statusCode)"
        context["bytes"] = "\(data.count)"
        Log.debug(.network, "Request finished", context)
        return (data, http)
    }

    /// `perform` + a 2xx check.
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await perform(request)
        let error: APIError
        switch response.statusCode {
        case 200..<300: return data
        case 401: error = .notAuthenticated
        default: error = .httpStatus(response.statusCode)
        }
        Log.error(.network, "Server returned an error", error: error, [
            "path": request.url?.path ?? "?",
            "status": "\(response.statusCode)",
            "body": Self.bodySnippet(data),
        ])
        throw error
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            Log.error(.network, "Response failed to decode", error: error, ["type": "\(type)", "body": bodySnippet(data)])
            throw error
        }
    }

    private static func milliseconds(since start: Date) -> String {
        "\(Int(Date().timeIntervalSince(start) * 1000))"
    }

    private static func bodySnippet(_ data: Data) -> String {
        guard let text = String(data: data.prefix(500), encoding: .utf8) else { return "<\(data.count) bytes>" }
        return data.count > 500 ? text + "…" : text
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
    // The server still requires an int "sentence"; progress is per
    // chapter now, so it's always 0.
    let sentenceIndex = 0

    enum CodingKeys: String, CodingKey {
        case bookID = "book_id"
        case chapterIndex = "chapter"
        case sentenceIndex = "sentence"
    }
}

private struct FilterWordsRequestBody: Encodable {
    let rules: [FilterWordRule]
}

private struct TranslateRequestBody: Encodable {
    let bookID: Int
    let chapter: Int
    let texts: [String]
    let source: String
    let target: String

    enum CodingKeys: String, CodingKey {
        case bookID = "book_id"
        case chapter, texts, source, target
    }
}

private struct GlossaryBody: Codable {
    let terms: [GlossaryTerm]
}

private struct TranslateResponseBody: Decodable {
    let translations: [String]
}

private struct StoredTranslationsBody: Decodable {
    struct Chapter: Decodable {}
    let chapters: [Chapter]
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
