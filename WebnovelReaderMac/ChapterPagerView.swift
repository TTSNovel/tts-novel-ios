import SwiftUI
import Core

/// macOS's chapter pager — no touch-swipe surface to back a
/// `UIPageViewController`-style paging gesture the way iOS's
/// `ChapterPagerView` has (see its doc comment), so this is plain
/// prev/next chrome (toolbar buttons + ⌘←/⌘→) around the same
/// platform-agnostic `ChapterPageContent` iOS's pager also renders.
struct ChapterPagerView: View {
    let book: Book
    let initialChapterIndex: Int

    @EnvironmentObject private var playback: ReaderPlaybackController
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var session: SessionStore

    private var isCurrentSession: Bool { playback.book?.id == book.id }
    private var currentIndex: Int { isCurrentSession ? playback.chapterIndex : initialChapterIndex }

    var body: some View {
        ChapterPageContent(book: book, index: currentIndex)
            .environmentObject(playback)
            .environmentObject(network)
            .environmentObject(session)
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        playback.skipChapter(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(currentIndex <= 0)
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .help("Chương trước")

                    Button {
                        playback.skipChapter(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(currentIndex + 1 >= book.n)
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .help("Chương sau")
                }
            }
    }
}
