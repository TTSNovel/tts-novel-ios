import SwiftUI

/// Scrolls the reader roughly a visible page at a time for Page Up/Page
/// Down. SwiftUI's macOS `ScrollView` exposes no raw offset/paging API,
/// and never becomes first responder on its own so plain AppKit key
/// handling never reaches it either — and reaching for the backing
/// `NSScrollView` directly (via `enclosingScrollView`) turned out to be a
/// dead end too: on this SDK its `documentView.frame.height` reports the
/// *viewport* height rather than the real content height, so every
/// page-scroll computed as a no-op. `ChapterPageContent` instead publishes
/// each sentence's Y position (in the "chapterScroll" coordinate space) via
/// `SentenceFramePreferenceKey`, and its own outer `GeometryReader` supplies
/// `viewportHeight` directly; `scrollPage(up:)` finds whichever sentence
/// sits ~one page away from the current top and jumps
/// `ScrollViewReader.scrollTo` there — same mechanism the highlight-driven
/// auto-scroll already uses, just aimed at a different target.
final class ScrollPageCoordinator: ObservableObject {
    var proxy: ScrollViewProxy?
    var sentenceFrames: [Int: CGFloat] = [:]
    var viewportHeight: CGFloat = 0

    func scrollPage(up: Bool) {
        guard let proxy, viewportHeight > 0 else { return }
        let sorted = sentenceFrames.sorted { $0.value < $1.value }
        guard !sorted.isEmpty else { return }
        let currentTopY = sorted.min(by: { abs($0.value) < abs($1.value) })?.value ?? 0
        let targetY = currentTopY + (up ? -viewportHeight : viewportHeight)
        let target = sorted.last(where: { $0.value <= targetY }) ?? (up ? sorted.first : sorted.last)
        guard let target else { return }
        withAnimation {
            proxy.scrollTo(target.key, anchor: .top)
        }
    }
}

struct SentenceFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] { [:] }
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
