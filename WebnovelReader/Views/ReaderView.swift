import SwiftUI

struct ReaderView: View {
    let book: Book

    @State private var chapterIndex: Int
    @State private var chapter: Chapter?
    @State private var loadError: String?
    @State private var shouldAutoPlayNextChapter = false
    @StateObject private var playback = ReaderPlaybackController()

    @EnvironmentObject private var downloads: DownloadManager

    init(book: Book, chapterIndex: Int) {
        self.book = book
        _chapterIndex = State(initialValue: chapterIndex)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let chapter {
                        Text(chapter.title).font(.title2.bold())
                        chapterBody(chapter)
                    } else if let loadError {
                        Text(loadError).foregroundStyle(.secondary)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    if playback.sentenceCount > 0 {
                        progressRow
                    }
                    if let error = playback.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .onChange(of: playback.highlightedSentenceIndex) { _, newValue in
                guard let newValue else { return }
                withAnimation {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                voiceMenu
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    goTo(chapterIndex - 1)
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .disabled(chapterIndex <= 0)

                Spacer()

                Button {
                    togglePlayback()
                } label: {
                    if playback.isLoadingAudio {
                        ProgressView()
                    } else {
                        Label(
                            playback.isPlaying ? "Tạm dừng" : "Đọc",
                            systemImage: playback.isPlaying ? "pause.fill" : "play.fill"
                        )
                    }
                }
                .disabled(chapter == nil)
                .accessibilityIdentifier("playPauseButton")

                Spacer()

                Button {
                    goTo(chapterIndex + 1)
                } label: {
                    Image(systemName: "forward.end.fill")
                }
                .disabled(chapterIndex >= book.n - 1)
            }
        }
        .task(id: chapterIndex) {
            await loadChapter()
        }
        .onAppear {
            playback.player.onNextChapter = { goTo(chapterIndex + 1) }
            playback.player.onPreviousChapter = { goTo(chapterIndex - 1) }
            playback.onChapterFinished = { handleChapterFinished() }
        }
        .onDisappear {
            playback.stop()
        }
    }

    /// Plain text until playback has actually segmented the chapter into
    /// sentences (reader.js only wraps <span data-r-s> once reading
    /// starts, too — see wrapContentSentences' call site in start()).
    /// Once it has, render one sentence per line so the currently-playing
    /// one can be highlighted and scrolled to.
    @ViewBuilder
    private func chapterBody(_ chapter: Chapter) -> some View {
        if playback.sentences.isEmpty {
            Text(chapter.text).font(.body)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(playback.sentences.enumerated()), id: \.offset) { index, sentence in
                    Text(sentence)
                        .font(.body)
                        .id(index)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .background(
                            index == playback.highlightedSentenceIndex
                                ? Color.accentColor.opacity(0.18) : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }

    private var progressRow: some View {
        HStack {
            Text("Câu \(min(playback.currentSentenceIndex + 1, playback.sentenceCount))/\(playback.sentenceCount)")
            Spacer()
            Text("Đã tải trước: \(playback.preloadedCount)/\(playback.sentenceCount)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var voiceMenu: some View {
        Menu {
            Picker("Giọng đọc", selection: $playback.voice) {
                ForEach(TTSVoice.allCases) { voice in
                    Text(voice.displayName).tag(voice)
                }
            }
            Picker("Tốc độ", selection: $playback.speed) {
                ForEach([0.85, 1.0, 1.15, 1.3, 1.5], id: \.self) { speed in
                    Text("\(speed, specifier: "%.2g")x").tag(speed)
                }
            }
            Toggle("Tự động sang chương tiếp", isOn: $playback.autoNextChapter)
            Picker("Hẹn giờ tắt", selection: $playback.autoStopMinutes) {
                Text("Tắt").tag(0.0)
                ForEach([15.0, 30.0, 45.0, 60.0, 90.0, 120.0], id: \.self) { minutes in
                    Text("\(Int(minutes)) phút").tag(minutes)
                }
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityIdentifier("voiceMenuButton")
    }

    private func goTo(_ index: Int) {
        guard index >= 0, index < book.n else { return }
        playback.stop()
        chapter = nil
        chapterIndex = index
    }

    private func togglePlayback() {
        guard let chapter else { return }
        playback.togglePlay(text: chapter.text, baseURL: SessionStore.baseURL)
    }

    /// A chapter finished playing on its own (not stopped/errored/manually
    /// navigated). If auto-next is on and there's another chapter, jump to
    /// it without stopping playback state — loadChapter() picks up
    /// `shouldAutoPlayNextChapter` and continues the same listening
    /// session (sleep timer keeps counting) instead of starting a fresh one.
    private func handleChapterFinished() {
        guard playback.autoNextChapter, chapterIndex < book.n - 1 else {
            playback.abandonSleepTimerIfIdle()
            return
        }
        shouldAutoPlayNextChapter = true
        chapter = nil
        chapterIndex += 1
    }

    private func loadChapter() async {
        loadError = nil
        let continuing = shouldAutoPlayNextChapter
        if !continuing {
            playback.stop()
        }

        if let local = downloads.localChapter(bookID: book.id, index: chapterIndex) {
            chapter = local
            playback.player.updateNowPlaying(bookTitle: book.title, chapterTitle: local.title)
            resumeAutoPlayIfNeeded(local)
            return
        }

        do {
            let fetched = try await APIClient.shared.fetchChapter(
                baseURL: SessionStore.baseURL, bookID: book.id, index: chapterIndex
            )
            chapter = fetched
            playback.player.updateNowPlaying(bookTitle: book.title, chapterTitle: fetched.title)
            resumeAutoPlayIfNeeded(fetched)
        } catch {
            loadError = "Không tải được nội dung chương"
        }
    }

    private func resumeAutoPlayIfNeeded(_ chapter: Chapter) {
        guard shouldAutoPlayNextChapter else { return }
        shouldAutoPlayNextChapter = false
        playback.continueToNextChapter(text: chapter.text, baseURL: SessionStore.baseURL)
    }
}

#Preview {
    NavigationStack {
        ReaderView(book: Book(id: 1, title: "Truyện mẫu", author: nil, category: "Demo", n: 3, cover: nil), chapterIndex: 0)
    }
    .environmentObject(SessionStore.shared)
    .environmentObject(DownloadManager.shared)
}
