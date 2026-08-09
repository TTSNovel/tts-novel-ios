import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var downloads: DownloadManager

    @State private var books: [Book] = []
    @State private var loadError: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List(books) { book in
                NavigationLink(value: book) {
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
                        }
                        Spacer()
                        if downloads.isDownloaded(book.id) {
                            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("WebnovelReader")
            .navigationDestination(for: Book.self) { book in
                BookDetailView(book: book)
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
                } else if let loadError, books.isEmpty {
                    ContentUnavailableView(
                        "Không tải được thư viện", systemImage: "wifi.slash", description: Text(loadError)
                    )
                }
            }
            .task {
                await loadBooks()
            }
        }
    }

    private func loadBooks() async {
        isLoading = true
        defer { isLoading = false }
        do {
            books = try await APIClient.shared.fetchBooks(baseURL: SessionStore.baseURL)
            loadError = nil
        } catch {
            loadError = "Kiểm tra kết nối mạng hoặc đăng nhập lại"
        }
    }
}

#Preview {
    LibraryView()
        .environmentObject(SessionStore.shared)
        .environmentObject(DownloadManager.shared)
}
