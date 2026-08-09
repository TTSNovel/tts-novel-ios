import SwiftUI

/// Standalone chapter picker reachable from inside ReaderView itself — a
/// separate popup from BookDetailView's own inline "Danh sách chương"
/// section, so switching chapters mid-read doesn't require backing all the
/// way out to the book detail page. Auto-scrolls to and highlights whichever
/// chapter is currently open the moment it appears.
struct ChapterListSheet: View {
    let book: Book
    let currentChapterIndex: Int
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var chapterTitles: [String]?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(0..<book.n, id: \.self) { index in
                    let isCurrent = index == currentChapterIndex
                    Button {
                        dismiss()
                        onSelect(index)
                    } label: {
                        HStack {
                            Text(chapterLabel(for: index))
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                                .fontWeight(isCurrent ? .semibold : .regular)
                            Spacer()
                            if isCurrent {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .id(index)
                    .listRowBackground(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear)
                    .accessibilityIdentifier("chapterListRow")
                }
                .listStyle(.plain)
                .task {
                    chapterTitles = await ChapterTitles.load(book: book)
                }
                .task {
                    // List needs a beat to lay out its rows before a
                    // ScrollViewReader.scrollTo against them actually lands
                    // — dispatching to the next runloop turn (rather than
                    // scrolling synchronously in .onAppear) is what makes
                    // this reliably jump straight to the current chapter
                    // even deep into a long book, instead of opening at the
                    // top.
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    proxy.scrollTo(currentChapterIndex, anchor: .center)
                }
            }
            .navigationTitle("Danh sách chương")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
    }

    private func chapterLabel(for index: Int) -> String {
        guard let titles = chapterTitles, titles.indices.contains(index), !titles[index].isEmpty else {
            return "Chương \(index + 1)"
        }
        return titles[index]
    }
}

#Preview {
    ChapterListSheet(
        book: Book(id: 1, title: "Truyện mẫu", author: nil, category: "Demo", n: 40, cover: nil),
        currentChapterIndex: 12,
        onSelect: { _ in }
    )
}
