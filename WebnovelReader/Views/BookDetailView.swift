import SwiftUI

struct BookDetailView: View {
    let book: Book

    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    CoverImage(book: book)
                        .frame(width: 140, height: 187)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text(book.title).font(.title3.bold()).multilineTextAlignment(.center)
                    if let author = book.author {
                        Text(author).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("\(book.n) chương · \(book.category)").font(.caption).foregroundStyle(.secondary)
                    downloadControl
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }

            Section("Danh sách chương") {
                ForEach(0..<book.n, id: \.self) { index in
                    NavigationLink {
                        ReaderView(book: book, chapterIndex: index)
                    } label: {
                        Text("Chương \(index + 1)")
                    }
                }
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var downloadControl: some View {
        if downloads.isDownloaded(book.id) {
            Button(role: .destructive) {
                downloads.deleteDownload(bookID: book.id)
            } label: {
                Label("Xoá bản tải xuống", systemImage: "trash")
            }
        } else if downloads.downloading.contains(book.id) {
            ProgressView(value: downloads.progress[book.id] ?? 0)
                .frame(maxWidth: 200)
        } else {
            Button {
                Task { await downloads.download(book: book, baseURL: SessionStore.baseURL) }
            } label: {
                Label("Tải xuống để đọc offline", systemImage: "arrow.down.circle")
            }
        }
    }
}

#Preview {
    NavigationStack {
        BookDetailView(book: Book(id: 1, title: "Truyện mẫu", author: nil, category: "Demo", n: 3, cover: nil))
    }
    .environmentObject(SessionStore.shared)
    .environmentObject(DownloadManager.shared)
}
