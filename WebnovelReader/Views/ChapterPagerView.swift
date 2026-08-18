import SwiftUI
import UIKit

// Matches book_renderer.py's `.reading` CSS (`rgba(255, 220, 50, 0.6)`
// background, `rgba(255, 180, 0, 0.65)` outline) exactly — a fixed warm
// yellow/orange rather than an adaptive system color, because it's chosen
// specifically to stay legible against both a near-white and a near-black
// page background. accentColor.opacity(...) (the old iOS highlight) reads
// fine in light mode but washes out to near-invisible in dark mode.
private extension Color {
    static let readingHighlight = Color(red: 1, green: 220 / 255, blue: 50 / 255).opacity(0.6)
    static let readingHighlightOutline = Color(red: 1, green: 180 / 255, blue: 0).opacity(0.65)
}

/// Native horizontal chapter pager backed by `UIPageViewController` instead
/// of SwiftUI's `TabView(.page)`. `.page`-style `TabView` doesn't actually
/// track a drag 1:1 the way a real paginated scroll view does — past
/// roughly the halfway point it decides the page has "turned" and starts
/// animating there on its own, independent of whether the finger is still
/// down, which is what produced "already animated to the next page before
/// release" / "jumps two pages" on a slow, deliberate drag (a quick flick
/// doesn't show it because the finger is usually already gone by the time
/// that fires). No amount of gating *our* reaction to the resulting
/// `selection` change fixes that, because the glitch is in `TabView`'s own
/// gesture handling, not in code reacting to it.
///
/// `UIPageViewController` is Apple's own dedicated paging component — what
/// Books/News/Photos use — and tracks the touch for the *entire* drag,
/// only deciding whether to commit to the neighbor or snap back once the
/// finger actually lifts. Its delegate only fires
/// `didFinishAnimating(transitionCompleted:)` once that's genuinely
/// settled, so real navigation only ever happens after a swipe has truly
/// committed — never mid-gesture, and never for a swipe that got dragged
/// partway and released back.
struct ChapterPagerView: UIViewControllerRepresentable {
    let book: Book
    let initialChapterIndex: Int

    @EnvironmentObject private var playback: ReaderPlaybackController
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var session: SessionStore

    private var isCurrentSession: Bool { playback.book?.id == book.id }
    private var startIndex: Int { isCurrentSession ? playback.chapterIndex : initialChapterIndex }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageVC = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        pageVC.dataSource = context.coordinator
        pageVC.delegate = context.coordinator
        pageVC.view.backgroundColor = .systemBackground
        pageVC.setViewControllers(
            [context.coordinator.pageController(for: startIndex)], direction: .forward, animated: false
        )
        context.coordinator.currentIndex = startIndex
        return pageVC
    }

    /// Only ever pushes a *programmatic* page change (button taps,
    /// ChapterListSheet jumps, lock-screen skip, or our own swipe-driven
    /// `skipChapter` call reflecting back into `playback.chapterIndex`) —
    /// the early-return below is what stops that last case from re-driving
    /// `setViewControllers` right after the swipe already put the correct
    /// page on screen.
    func updateUIViewController(_ pageViewController: UIPageViewController, context: Context) {
        context.coordinator.book = book
        context.coordinator.playback = playback
        context.coordinator.network = network
        context.coordinator.session = session

        let target = startIndex
        guard target != context.coordinator.currentIndex else { return }
        let direction: UIPageViewController.NavigationDirection = target > context.coordinator.currentIndex ? .forward : .reverse
        context.coordinator.currentIndex = target
        pageViewController.setViewControllers(
            [context.coordinator.pageController(for: target)], direction: direction, animated: true
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(book: book, playback: playback, network: network, session: session)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var book: Book
        var playback: ReaderPlaybackController
        var network: NetworkMonitor
        var session: SessionStore
        /// The chapter index we last told the `UIPageViewController` to
        /// show — used to compute swipe delta/direction and to detect
        /// "already showing this" in `updateUIViewController`.
        var currentIndex = 0

        init(book: Book, playback: ReaderPlaybackController, network: NetworkMonitor, session: SessionStore) {
            self.book = book
            self.playback = playback
            self.network = network
            self.session = session
        }

        func pageController(for index: Int) -> UIViewController {
            // Wrapped in AnyView so `ChapterPageHostingController` can stay
            // a concrete (non-generic) type — `.environmentObject(...)`
            // returns an opaque `ModifiedContent<...>` type that's a pain
            // to name otherwise.
            let content = AnyView(
                ChapterPageContent(book: book, index: index)
                    .environmentObject(playback)
                    .environmentObject(network)
                    .environmentObject(session)
            )
            let hosting = ChapterPageHostingController(rootView: content)
            hosting.chapterIndex = index
            return hosting
        }

        func pageViewController(
            _ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let index = (viewController as? ChapterPageHostingController)?.chapterIndex, index > 0 else { return nil }
            return pageController(for: index - 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let index = (viewController as? ChapterPageHostingController)?.chapterIndex, index + 1 < book.n else { return nil }
            return pageController(for: index + 1)
        }

        /// Fires only once a swipe has genuinely settled — either committed
        /// to a neighbor (`completed == true`) or snapped back to where it
        /// started (`completed == false`: dragged partway, released without
        /// enough distance/velocity) — never mid-gesture. Mirrors tapping
        /// PlaybackBar's prev/next button: continues playback into the new
        /// chapter if something was playing, otherwise just loads it (see
        /// `ReaderPlaybackController.skipChapter`).
        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard completed, let visible = pageViewController.viewControllers?.first as? ChapterPageHostingController else { return }
            let newIndex = visible.chapterIndex
            guard newIndex != currentIndex else { return }
            // The dataSource above only ever hands out adjacent ±1
            // controllers, so this is always exactly +1 or -1 — computed
            // before overwriting `currentIndex` below.
            let delta = newIndex > currentIndex ? 1 : -1
            currentIndex = newIndex
            playback.skipChapter(by: delta)
        }
    }
}

/// Tags a hosting controller with which chapter it's showing — the
/// dataSource callbacks need to know "which page is this, so what comes
/// before/after it," and there's no other stable identity to hang that off.
private final class ChapterPageHostingController: UIHostingController<AnyView> {
    var chapterIndex = 0
}

/// One page's content — the actually-open chapter renders interactively
/// (sentence-highlighted, auto-scrolling, tap-to-seek); any other chapter
/// (a neighbor the pager has paged to but hasn't committed navigation for
/// yet, or before the session has caught up to it) renders a plain,
/// non-interactive preview sourced from `ReaderPlaybackController`'s
/// prefetch cache.
private struct ChapterPageContent: View {
    let book: Book
    let index: Int

    @EnvironmentObject private var playback: ReaderPlaybackController
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var session: SessionStore

    private var isCurrentSession: Bool { playback.book?.id == book.id }
    private var isLive: Bool { isCurrentSession && index == playback.chapterIndex }

    var body: some View {
        if isLive {
            livePage
        } else {
            previewPage
        }
    }

    private var livePage: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let chapter = playback.chapter {
                        chapterBody(chapter)
                    } else if let error = playback.loadError {
                        Text(error).foregroundStyle(.secondary)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    // /api/tts requires login even though reading itself is
                    // public — ReaderPlaybackController.makeFetchTask falls
                    // back to the on-device voice for the exact same two
                    // reasons this footnote covers, so keep them in sync.
                    if (!network.isConnected || !session.isLoggedIn) && !playback.voice.isOffline {
                        Text(
                            network.isConnected
                                ? "Chế độ khách — tạm dùng giọng đọc ngoại tuyến (đăng nhập ở Cài đặt để dùng giọng online)"
                                : "Đang offline — tạm dùng giọng đọc ngoại tuyến"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    if let error = playback.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                // Each page is its own UIHostingController rather than a
                // shared SwiftUI ancestor, so PlaybackBar's reserved space
                // (normally one `.safeAreaInset` on a common container)
                // can't be applied once above the pager — add it directly
                // to every page's content instead.
                .padding(.bottom, PlaybackBar.reservedHeight)
            }
            .onChange(of: playback.highlightedSentenceIndex) { _, newValue in
                guard let newValue else { return }
                withAnimation {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    /// Plain title+text until playback has actually segmented the chapter
    /// (reader.js only wraps <span data-r-s> once reading starts, too —
    /// see wrapContentSentences' call site in start()). Once it has,
    /// render one sentence per line so the currently-playing one can be
    /// highlighted and scrolled to — sentence 0 is always the chapter
    /// title (see ReaderPlaybackController.sentenceSequence, which is what
    /// makes read-aloud announce the chapter before its body), rendered
    /// with the same bold/title styling the plain-text branch below gives
    /// it as a separate header, so there's no visible duplicate.
    @ViewBuilder
    private func chapterBody(_ chapter: Chapter) -> some View {
        if playback.sentences.isEmpty {
            Text(chapter.title).font(.title2.bold())
            Text(chapter.text).font(.body)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(playback.sentences.enumerated()), id: \.offset) { sentenceIndex, sentence in
                    let isHighlighted = sentenceIndex == playback.highlightedSentenceIndex
                    Text(sentence)
                        .font(sentenceIndex == 0 ? .title2.bold() : .body)
                        .id(sentenceIndex)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .background(isHighlighted ? Color.readingHighlight : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.readingHighlightOutline, lineWidth: isHighlighted ? 2 : 0)
                        )
                        // Tapping a line jumps read-aloud straight to it —
                        // contentShape widens the hit target to the full
                        // padded row instead of just the glyphs themselves.
                        .contentShape(Rectangle())
                        .onTapGesture { playback.seek(to: sentenceIndex) }
                        .accessibilityIdentifier("sentenceText_\(sentenceIndex)")
                }
            }
        }
    }

    /// A neighboring chapter's plain title + text, sourced from
    /// `playback.cachedChapter(index:)` — never interactive/highlighted
    /// (that only makes sense for whichever chapter is actually "open").
    /// Falls back to a spinner + on-appear prefetch if the swipe reached
    /// here before the neighbor-prefetch (kicked off from `loadChapter`)
    /// had a chance to land.
    private var previewPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let chapter = playback.cachedChapter(index: index) {
                    Text(chapter.title).font(.title2.bold())
                    Text(chapter.text).font(.body)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task { await playback.prefetchChapter(index: index) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .padding(.bottom, PlaybackBar.reservedHeight)
        }
    }
}
