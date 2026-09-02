import SwiftUI
import Core

/// Watch-native library list — reuses `BookRow`/`CoverImage` directly from
/// the iOS Views/ (both are already decoupled from `ReaderPlaybackController`,
/// only touching `Core` + `DownloadManager`/`ProgressStore`, so they render
/// identically here). Adds search and a "recently read" section on top of
/// iOS's own list, same as LibraryView's shape — not a stripped-down port.
struct WatchLibraryView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var downloads: DownloadManager
    @State private var books: [Book] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var showingSettings = false

    private var filteredBooks: [Book] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return books }
        return books.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    /// Up to 3 most recently read books still present in the current
    /// library listing, newest first — hidden entirely while searching.
    private var recentBooks: [Book] {
        guard searchText.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
        return progressStore.recentEntries(limit: 3).compactMap { byID[$0.bookID] }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if let errorMessage {
                    VStack(spacing: 8) {
                        Text(errorMessage).font(.footnote).multilineTextAlignment(.center)
                        Button("Thử lại") { Task { await loadBooks() } }
                            .accessibilityIdentifier("libraryRetryButton")
                    }
                    .padding()
                } else {
                    List {
                        if !recentBooks.isEmpty {
                            Section("Đọc gần đây") {
                                ForEach(recentBooks) { book in
                                    NavigationLink {
                                        WatchBookDetailView(book: book)
                                    } label: {
                                        BookRow(book: book)
                                    }
                                    .accessibilityIdentifier("recentBookRow_\(book.id)")
                                }
                            }
                        }
                        Section(recentBooks.isEmpty ? "" : "Tất cả sách") {
                            ForEach(filteredBooks) { book in
                                NavigationLink {
                                    WatchBookDetailView(book: book)
                                } label: {
                                    BookRow(book: book)
                                }
                                .accessibilityIdentifier("bookRow_\(book.id)")
                            }
                        }
                    }
                    .searchable(text: $searchText, prompt: "Tìm sách")
                    .accessibilityIdentifier("libraryList")
                }
            }
            .navigationTitle("Novel Reader")
            .toolbar {
                ToolbarItem(placement: .readerTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityIdentifier("settingsButton")
                }
            }
            .sheet(isPresented: $showingSettings) {
                WatchSettingsView(isPresented: $showingSettings)
            }
            .task {
                await session.restoreSession()
                await loadBooks()
            }
        }
    }

    private func loadBooks() async {
        isLoading = true
        errorMessage = nil
        do {
            books = try await APIClient.shared.fetchBooks(baseURL: SessionStore.baseURL)
        } catch {
            let offline = downloads.downloadedBooks()
            if !offline.isEmpty {
                books = offline
            } else {
                errorMessage = "Không tải được thư viện — kiểm tra kết nối mạng"
            }
        }
        isLoading = false
    }
}
