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
    @EnvironmentObject private var session: SessionStore
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
            List(books) { book in
                NavigationLink(value: book) {
                    bookRow(book)
                }
                .accessibilityIdentifier("bookRow")
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Đăng xuất") { session.logout() }
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

    // Split out of the List's row closure — SwiftUI's ViewBuilder type
    // inference chokes on too many mixed if-let/plain statements in one
    // closure and reports the failure at an unrelated call site (was
    // surfacing as "cannot convert [Book] to Range<Int>" on `List(books)`
    // itself once the progress-badge line was added inline).
    @ViewBuilder
    private func bookRow(_ book: Book) -> some View {
        HStack(spacing: 12) {
            CoverImage(book: book)
                .frame(width: 48, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.headline)
                if let author = book.author {
                    Text(author).font(.subheadline).foregroundStyle(.secondary)
                }
                Text("\(book.n) chương").font(.caption).foregroundStyle(.secondary)
                if let progress = progressStore.localProgress(bookID: book.id) {
                    Text("Đang đọc: Chương \(progress.chapterIndex + 1)/\(book.n)")
                        .font(.caption).foregroundStyle(Color.accentColor)
                }
            }
            Spacer()
            if downloads.isDownloaded(book.id) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
            }
        }
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
}
