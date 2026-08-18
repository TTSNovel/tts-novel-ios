import SwiftUI

// Presentation-only now — all playback/chapter state lives on the shared
// ReaderPlaybackController (see its doc comment) so that backing out to
// BookDetailView/Library doesn't stop anything, the way Music/Podcasts
// keep playing while you browse elsewhere. This view just tells the
// controller what to open once, then renders whatever it publishes.
//
// The actual paged content lives in ChapterPagerView (UIPageViewController-
// backed — see its doc comment for why this isn't a SwiftUI TabView). This
// view is just the glue around it: navigation title/toolbar, the chapter
// list sheet, and the open()/progress-sync lifecycle.
struct ReaderView: View {
    let book: Book
    let initialChapterIndex: Int

    @EnvironmentObject private var playback: ReaderPlaybackController
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingChapterList = false

    init(book: Book, chapterIndex: Int) {
        self.book = book
        self.initialChapterIndex = chapterIndex
    }

    /// False while the controller is still showing a *different* book (or
    /// hasn't opened this one yet) — e.g. the brief window right after
    /// tapping into this book before its chapter has loaded, or if some
    /// other book is currently playing and this screen hasn't taken over
    /// yet.
    private var isCurrentSession: Bool { playback.book?.id == book.id }
    private var currentChapterIndex: Int { isCurrentSession ? playback.chapterIndex : initialChapterIndex }

    var body: some View {
        ChapterPagerView(book: book, initialChapterIndex: initialChapterIndex)
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingChapterList = true
                } label: {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel("Danh sách chương")
                .accessibilityIdentifier("chapterListButton")
            }
        }
        .sheet(isPresented: $showingChapterList) {
            ChapterListSheet(book: book, currentChapterIndex: currentChapterIndex) { index in
                Task { await playback.goTo(index) }
            }
        }
        .readerSettingsToolbar()
        .task {
            await playback.open(book: book, chapterIndex: initialChapterIndex)
        }
        .onDisappear {
            syncProgress()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background { syncProgress() }
        }
    }

    private func syncProgress() {
        Task { await ProgressStore.shared.syncToServer(bookID: book.id) }
    }
}

#Preview {
    NavigationStack {
        ReaderView(book: Book(id: 1, title: "Truyện mẫu", author: nil, category: "Demo", n: 3, cover: nil), chapterIndex: 0)
    }
    .environmentObject(SessionStore.shared)
    .environmentObject(ReaderPlaybackController.shared)
    .environmentObject(NetworkMonitor.shared)
}
