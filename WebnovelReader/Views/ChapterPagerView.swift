import SwiftUI
import UIKit
import Core

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

