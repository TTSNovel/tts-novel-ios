import SwiftUI
import Core

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
    @State private var searchText = ""

    /// Up to 5 most recent chapters, newest first. Hidden when the book is
    /// short enough that it would just duplicate the full list below.
    private var newestIndices: [Int] {
        guard book.n > 5 else { return [] }
        return Array((book.n - 5..<book.n).reversed())
    }

    /// Local filter over every chapter — nil while the search field is
    /// empty, since we still have all chapters loaded up front there's no
    /// need to hit the network to search.
    private var filteredIndices: [Int]? {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let queryNumber = Int(query)
        return (0..<book.n).filter { index in
            if let queryNumber, index + 1 == queryNumber { return true }
            return chapterLabel(for: index).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                chapterContainer
                    .modifier(CommonChapterListModifiers(searchText: $searchText, currentChapterIndex: currentChapterIndex, proxy: proxy) {
                        chapterTitles = await ChapterTitles.load(book: book)
                    })
            }
            .navigationTitle("Danh sách chương")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var chapterContainer: some View {
        #if os(macOS)
        // ScrollView+LazyVStack, not List: SwiftUI's List on macOS is
        // NSTableView-backed, and for a book with ~2000 chapters that
        // backing takes several seconds (confirmed empirically: up to
        // ~30s across repeated runs, vs. ~3s for the exact same book/data
        // through List's UICollectionView backing on iOS) just to finish
        // its initial layout pass — during which the sheet looks
        // completely empty, indistinguishable from broken. LazyVStack in a
        // plain ScrollView doesn't have that mount cost on macOS.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                chapterSections
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #else
        // Was .plain, but plain-style section headers pin/float with a
        // translucent background while scrolling, letting the row just
        // scrolled past show through behind the header text (visible as
        // e.g. "2764" ghosted behind "Chương mới nhất"). The default
        // (inset-grouped) style gives each section an opaque card
        // background instead, so nothing bleeds through — same style
        // BookDetailView's own chapter list already uses without this
        // problem.
        List {
            chapterSections
        }
        #endif
    }

    @ViewBuilder
    private var chapterSections: some View {
        if let filteredIndices {
            Section {
                if filteredIndices.isEmpty {
                    Text("Không tìm thấy chương phù hợp")
                        .foregroundStyle(.secondary)
                        #if os(macOS)
                        .padding(.horizontal)
                        #endif
                } else {
                    ForEach(filteredIndices, id: \.self) { index in
                        chapterRow(for: index, idPrefix: "search")
                    }
                }
            } header: {
                sectionHeader("Kết quả tìm kiếm")
            }
        } else {
            if !newestIndices.isEmpty {
                Section {
                    ForEach(newestIndices, id: \.self) { index in
                        chapterRow(for: index, idPrefix: "newest")
                    }
                } header: {
                    sectionHeader("Chương mới nhất")
                }
            }
            Section {
                ForEach(0..<book.n, id: \.self) { index in
                    chapterRow(for: index, idPrefix: "all")
                }
            } header: {
                sectionHeader("Tất cả chương")
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        #if os(macOS)
        // List (iOS) styles Section headers on its own; a bare LazyVStack
        // doesn't, so this fills in the same look manually on macOS.
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 4)
        #else
        Text(title)
        #endif
    }

    @ViewBuilder
    private func chapterRow(for index: Int, idPrefix: String) -> some View {
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
            #if os(macOS)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            #endif
        }
        .buttonStyle(.plain)
        .id("\(idPrefix)-\(index)")
        #if os(macOS)
        .background(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear)
        #else
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear)
        #endif
        .accessibilityIdentifier("chapterListRow")
    }

    private func chapterLabel(for index: Int) -> String {
        guard let titles = chapterTitles, titles.indices.contains(index), !titles[index].isEmpty else {
            return "Chương \(index + 1)"
        }
        return titles[index]
    }
}

/// Factors out the modifiers ChapterListSheet needs regardless of whether
/// its content sits in a List (iOS/watchOS) or a ScrollView+LazyVStack
/// (macOS) — both accept the same `.searchable`/`.task` attachments.
private struct CommonChapterListModifiers: ViewModifier {
    @Binding var searchText: String
    let currentChapterIndex: Int
    let proxy: ScrollViewProxy
    let loadTitles: () async -> Void

    func body(content: Content) -> some View {
        content
            .searchable(text: $searchText, prompt: "Tìm theo số chương hoặc tên")
            .task {
                await loadTitles()
            }
            .task {
                // List/LazyVStack needs a beat to lay out its rows before a
                // ScrollViewReader.scrollTo against them actually lands —
                // dispatching to the next runloop turn (rather than
                // scrolling synchronously in .onAppear) is what makes this
                // reliably jump straight to the current chapter even deep
                // into a long book, instead of opening at the top. Targets
                // the "all chapters" section specifically since that's the
                // one guaranteed to be showing (search starts empty) and to
                // contain every index.
                try? await Task.sleep(nanoseconds: 50_000_000)
                proxy.scrollTo("all-\(currentChapterIndex)", anchor: .center)
            }
    }
}

#Preview {
    ChapterListSheet(
        book: Book(id: 1, title: "Truyện mẫu", author: nil, category: "Demo", n: 40, cover: nil),
        currentChapterIndex: 12,
        onSelect: { _ in }
    )
}
