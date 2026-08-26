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
            if playback.translationSourceLanguage != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    translateButton
                }
            }
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
        .chapterTranslationSupport()
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

    /// Only ever added to the toolbar while `playback.translationSourceLanguage`
    /// is non-nil — i.e. the chapter's detected language differs from
    /// `primaryLanguage`, so there's actually something to translate.
    /// Deliberately stays hidden (rather than shown-but-disabled) when a
    /// chapter is already in the primary language: there's no source
    /// language to translate *from* in that case, and Apple's/OPUS-MT's
    /// `translate(...)` both require one — a "translate" tap here would
    /// have nothing meaningful to do.
    ///
    /// Shows a 2-letter language-code pill instead of a generic icon (an
    /// unfilled pill with the *source* language's code while showing the
    /// original, a filled pill with the *primary* language's code once
    /// showing the translation) so the button's current state is legible
    /// at a glance, rather than a globe icon whose fill/tint was easy to
    /// miss. While a translation is in flight, swaps to a determinate
    /// `ProgressView` (filled by `playback.translationProgress`, which the
    /// controller polls from whichever engine is running) instead of a
    /// bare spinner — a chapter with 100+ sentences can take tens of
    /// seconds, and an indeterminate spinner alone reads as "stuck."
    private var translateButton: some View {
        Button {
            playback.toggleTranslationDisplay()
        } label: {
            Group {
                if playback.isTranslating {
                    if let progress = playback.translationProgress, progress.total > 0 {
                        ProgressView(value: Double(progress.completed), total: Double(progress.total))
                            .progressViewStyle(.circular)
                    } else {
                        ProgressView()
                    }
                } else {
                    Text(languageCodeLabel)
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .frame(width: 26, height: 26)
            .background(Circle().fill(playback.showingTranslation ? Color.accentColor : Color.secondary.opacity(0.15)))
            .foregroundStyle(playback.showingTranslation ? Color.white : Color.primary)
        }
        .accessibilityLabel(translateButtonAccessibilityLabel)
        .accessibilityIdentifier("translateChapterButton")
    }

    /// Source language's code while showing the original, primary
    /// language's code once showing the translation — see `translateButton`.
    private var languageCodeLabel: String {
        let language = playback.showingTranslation ? playback.primaryLanguage : (playback.translationSourceLanguage ?? playback.primaryLanguage)
        return (language.languageCode?.identifier ?? "?").uppercased()
    }

    private var translateButtonAccessibilityLabel: String {
        if playback.isTranslating {
            if let progress = playback.translationProgress {
                return "Đang dịch, \(progress.completed) trên \(progress.total) câu"
            }
            return "Đang dịch"
        }
        return playback.showingTranslation ? "Xem bản gốc" : "Dịch sang \(languageCodeLabel)"
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
