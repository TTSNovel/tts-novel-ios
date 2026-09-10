import SwiftUI
import Core

/// macOS's chapter pager — no touch-swipe surface to back a
/// `UIPageViewController`-style paging gesture the way iOS's
/// `ChapterPagerView` has (see its doc comment), so this is plain
/// prev/next chrome (toolbar buttons + ←/→, plus hidden Page Up/Page Down
/// buttons that scroll a page at a time — see `ScrollPageCoordinator`)
/// around the same platform-agnostic `ChapterPageContent` iOS's pager also
/// renders.
struct ChapterPagerView: View {
    let book: Book
    let initialChapterIndex: Int

    @EnvironmentObject private var playback: ReaderPlaybackController
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var session: SessionStore
    @StateObject private var scrollPageCoordinator = ScrollPageCoordinator()

    private var isCurrentSession: Bool { playback.book?.id == book.id }
    private var currentIndex: Int { isCurrentSession ? playback.chapterIndex : initialChapterIndex }

    var body: some View {
        ChapterPageContent(book: book, index: currentIndex)
            .environmentObject(playback)
            .environmentObject(network)
            .environmentObject(session)
            .environmentObject(scrollPageCoordinator)
            .background {
                // Zero-size buttons purely to register the .pageUp/.pageDown
                // app-level shortcuts (same mechanism as the ←/→ chapter
                // buttons below) — SwiftUI's ScrollView never becomes first
                // responder on macOS, so plain key handling never reaches
                // it; ScrollPageCoordinator scrolls it directly instead.
                Button("") { scrollPageCoordinator.scrollPage(up: true) }
                    .keyboardShortcut(.pageUp, modifiers: [])
                    .buttonStyle(.plain)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                Button("") { scrollPageCoordinator.scrollPage(up: false) }
                    .keyboardShortcut(.pageDown, modifiers: [])
                    .buttonStyle(.plain)
                    .frame(width: 0, height: 0)
                    .opacity(0)
            }
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        playback.skipChapter(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(currentIndex <= 0)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .help("Chương trước")
                    .accessibilityIdentifier("prevChapterButton")

                    Button {
                        playback.skipChapter(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(currentIndex + 1 >= book.n)
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("Chương sau")
                    .accessibilityIdentifier("nextChapterButton")
                }
            }
    }
}
