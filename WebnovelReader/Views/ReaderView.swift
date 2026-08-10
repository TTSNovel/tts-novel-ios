import SwiftUI

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

// Presentation-only now — all playback/chapter state lives on the shared
// ReaderPlaybackController (see its doc comment) so that backing out to
// BookDetailView/Library doesn't stop anything, the way Music/Podcasts
// keep playing while you browse elsewhere. This view just tells the
// controller what to open once, then renders whatever it publishes.
struct ReaderView: View {
    let book: Book
    let initialChapterIndex: Int

    @EnvironmentObject private var playback: ReaderPlaybackController
    @EnvironmentObject private var network: NetworkMonitor
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
    /// yet. Gates content/controls so we never render/enable actions
    /// against another book's in-flight state.
    private var isCurrentSession: Bool { playback.book?.id == book.id }

    private var displayedChapter: Chapter? { isCurrentSession ? playback.chapter : nil }
    private var displayedLoadError: String? { isCurrentSession ? playback.loadError : nil }
    private var currentChapterIndex: Int { isCurrentSession ? playback.chapterIndex : initialChapterIndex }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let chapter = displayedChapter {
                        chapterBody(chapter)
                    } else if let displayedLoadError {
                        Text(displayedLoadError).foregroundStyle(.secondary)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    if !network.isConnected && playback.voice != .piperOffline {
                        Text("Đang offline — tạm dùng giọng đọc ngoại tuyến")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if isCurrentSession, let error = playback.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .onChange(of: isCurrentSession ? playback.highlightedSentenceIndex : nil) { _, newValue in
                guard let newValue else { return }
                withAnimation {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            // See PlaybackBar's doc comment — invisible spacer, not a
            // second bar (the one real PlaybackBar lives on LibraryView's
            // NavigationStack).
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: PlaybackBar.reservedHeight)
            }
        }
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
        if !isCurrentSession || playback.sentences.isEmpty {
            Text(chapter.title).font(.title2.bold())
            Text(chapter.text).font(.body)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(playback.sentences.enumerated()), id: \.offset) { index, sentence in
                    let isHighlighted = index == playback.highlightedSentenceIndex
                    Text(sentence)
                        .font(index == 0 ? .title2.bold() : .body)
                        .id(index)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .background(isHighlighted ? Color.readingHighlight : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.readingHighlightOutline, lineWidth: isHighlighted ? 2 : 0)
                        )
                }
            }
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
