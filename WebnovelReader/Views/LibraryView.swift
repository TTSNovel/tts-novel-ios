import SwiftUI

// Pushed onto navPath programmatically to deep-link straight into a
// chapter (see maybeAutoResume) — BookDetailView's own chapter-list rows
// stay closure-based NavigationLinks and don't need this type; both styles
// coexist fine on the same NavigationStack.
struct ChapterRoute: Hashable {
    let book: Book
    let chapterIndex: Int
}

struct LibraryView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var network: NetworkMonitor

    @State private var books: [Book] = []
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var isOfflineMode = false
    @State private var navPath = NavigationPath()
    @State private var didAutoResume = false

    var body: some View {
        NavigationStack(path: $navPath) {
            List {
                if !recentBooks.isEmpty {
                    Section {
                        ForEach(recentBooks) { book in
                            NavigationLink(value: book) {
                                BookRow(book: book)
                            }
                            .accessibilityIdentifier("bookRow")
                        }
                    } header: {
                        HStack {
                            Text("Đọc gần đây")
                            Spacer()
                            NavigationLink("Xem tất cả") {
                                HistoryView(books: historyBooks)
                            }
                            .accessibilityIdentifier("seeAllHistoryButton")
                        }
                        .textCase(nil)
                    }
                }

                Section {
                    ForEach(books) { book in
                        NavigationLink(value: book) {
                            BookRow(book: book)
                        }
                        .accessibilityIdentifier("bookRow")
                    }
                } header: {
                    if !recentBooks.isEmpty { Text("Tất cả") }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Novel Reader")
            .navigationDestination(for: Book.self) { book in
                BookDetailView(book: book)
            }
            .navigationDestination(for: ChapterRoute.self) { route in
                ReaderView(book: route.book, chapterIndex: route.chapterIndex)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        DownloadedBooksView()
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .accessibilityLabel("Đã tải xuống")
                }
            }
            .refreshable { await loadBooks() }
            .overlay {
                if isLoading && books.isEmpty {
                    ProgressView()
                } else if isOfflineMode && books.isEmpty {
                    // Distinct from the genuine-failure case below — this is
                    // the expected state the first time a user goes offline
                    // before ever downloading anything, not a bug.
                    ContentUnavailableView(
                        "Chưa có truyện tải xuống",
                        systemImage: "wifi.slash",
                        description: Text("Bạn đang offline. Kết nối mạng và tải truyện xuống để đọc offline sau này.")
                    )
                } else if let loadError, books.isEmpty {
                    ContentUnavailableView(
                        "Không tải được thư viện", systemImage: "wifi.slash", description: Text(loadError)
                    )
                }
            }
            .safeAreaInset(edge: .top) {
                if isOfflineMode && !books.isEmpty {
                    offlineBanner
                }
            }
            .task {
                await loadBooks()
                maybeAutoResume()
            }
            .onChange(of: network.isConnected) { _, connected in
                guard connected, isOfflineMode else { return }
                Task { await loadBooks() }
            }
            .readerSettingsToolbar()
        }
        // Attached once to the NavigationStack itself (not per-screen — see
        // PlaybackBar's doc comment for why per-screen attachment was tried
        // and reverted: every pushed screen stays mounted underneath in a
        // NavigationStack, so a PlaybackBar on each one renders N live
        // "playPauseButton"s simultaneously, which is both an accessibility
        // hazard and broke PlaybackPersistenceUITests) so it stays visible
        // — and singular — across every pushed screen (BookDetailView,
        // HistoryView, ReaderView), like Music/Podcasts.
        .safeAreaInset(edge: .bottom) {
            PlaybackBar()
        }
    }

    private var offlineBanner: some View {
        Label("Đang offline — chỉ hiện các truyện đã tải xuống.", systemImage: "wifi.slash")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
    }

    /// Top 5 most-recently-updated books that are actually still in the
    /// library list (a book could have progress from before it was removed/
    /// renamed — compactMap drops those instead of showing a dead row).
    private var recentBooks: [Book] {
        Array(historyBooks.prefix(5))
    }

    /// Every book with saved progress, most-recent first — the full list
    /// behind "Xem tất cả" (HistoryView), and the source recentBooks caps.
    private var historyBooks: [Book] {
        progressStore.recentEntries().compactMap { entry in books.first(where: { $0.id == entry.bookID }) }
    }

    private func loadBooks() async {
        isLoading = true
        defer { isLoading = false }
        do {
            books = try await APIClient.shared.fetchBooks(baseURL: SessionStore.baseURL)
            loadError = nil
            isOfflineMode = false
        } catch {
            guard NetworkMonitor.isNetworkError(error) else {
                isOfflineMode = false
                loadError = "Kiểm tra kết nối mạng hoặc đăng nhập lại"
                return
            }
            books = downloads.downloadedBooks()
            isOfflineMode = true
            loadError = nil
        }
    }

    /// Jumps straight into the most-recently-read book's chapter on launch
    /// — like resuming playback in an audiobook app — instead of leaving
    /// the user to find their place in the Library. Only ever runs once
    /// per app launch (`didAutoResume`), and the pushed path still leaves
    /// Library/BookDetail underneath so the back button works normally.
    private func maybeAutoResume() {
        guard !didAutoResume else { return }
        didAutoResume = true
        guard let recent = progressStore.mostRecentlyRead(),
              let book = books.first(where: { $0.id == recent.bookID }) else { return }
        navPath.append(book)
        navPath.append(ChapterRoute(book: book, chapterIndex: recent.progress.chapterIndex))
    }
}

#Preview {
    LibraryView()
        .environmentObject(SessionStore.shared)
        .environmentObject(DownloadManager.shared)
        .environmentObject(ProgressStore.shared)
        .environmentObject(NetworkMonitor.shared)
        .environmentObject(ReaderPlaybackController.shared)
}
