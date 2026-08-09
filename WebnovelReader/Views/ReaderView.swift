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

struct ReaderView: View {
    let book: Book

    @State private var chapterIndex: Int
    @State private var chapter: Chapter?
    @State private var loadError: String?
    @State private var shouldAutoPlayNextChapter = false
    @State private var hasCheckedResume = false
    @State private var showingSettings = false
    @StateObject private var playback = ReaderPlaybackController()

    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var network: NetworkMonitor
    @Environment(\.scenePhase) private var scenePhase

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
                    if !network.isConnected && playback.voice != .piperOffline {
                        Text("Đang offline — tạm dùng giọng đọc ngoại tuyến")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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

                Spacer()

                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityIdentifier("voiceMenuButton")
            }
        }
        .sheet(isPresented: $showingSettings) {
            settingsSheet
        }
        .task(id: chapterIndex) {
            await loadChapter()
        }
        .onAppear {
            playback.player.onNextChapter = { skipChapter(chapterIndex + 1) }
            playback.player.onPreviousChapter = { skipChapter(chapterIndex - 1) }
            playback.onChapterFinished = { handleChapterFinished() }
            playback.onSentenceChanged = { index in
                ProgressStore.shared.recordLocal(bookID: book.id, chapterIndex: chapterIndex, sentenceIndex: index)
            }
        }
        .onDisappear {
            playback.stop()
            syncProgress()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background { syncProgress() }
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
                    let isHighlighted = index == playback.highlightedSentenceIndex
                    Text(sentence)
                        .font(.body)
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

    private var progressRow: some View {
        HStack {
            Text("Câu \(min(playback.currentSentenceIndex + 1, playback.sentenceCount))/\(playback.sentenceCount)")
            Spacer()
            Text("Đã tải trước: \(playback.preloadedCount)/\(playback.sentenceCount)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// A `Menu` worked while this only held voice+speed, but it's since
    /// grown to 4+ independent settings (voice, speed, auto-next, sleep
    /// timer) — a dropdown menu forces every Picker into its own nested
    /// submenu and reads as a cramped, hard-to-scan list. A sheet gives
    /// each setting a properly laid-out row, grouped like the web
    /// version's settings panel (site_assets/reader.js's buildControlBar).
    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Giọng đọc") {
                    Picker("Giọng đọc", selection: $playback.voice) {
                        ForEach(TTSVoice.allCases) { voice in
                            Text(voice.displayName).tag(voice)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Tốc độ đọc") {
                    Picker("Tốc độ", selection: $playback.speed) {
                        ForEach([0.85, 1.0, 1.15, 1.3, 1.5], id: \.self) { speed in
                            Text("\(speed, specifier: "%.2g")x").tag(speed)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Tự động") {
                    Toggle("Tự động sang chương tiếp", isOn: $playback.autoNextChapter)
                    Picker("Hẹn giờ tắt", selection: $playback.autoStopMinutes) {
                        Text("Tắt").tag(0.0)
                        ForEach([15.0, 30.0, 45.0, 60.0, 90.0, 120.0], id: \.self) { minutes in
                            Text("\(Int(minutes)) phút").tag(minutes)
                        }
                    }
                }
            }
            .navigationTitle("Cài đặt đọc")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { showingSettings = false }
                }
            }
        }
    }

    private func goTo(_ index: Int) {
        guard index >= 0, index < book.n else { return }
        playback.stop()
        chapter = nil
        chapterIndex = index
        // Marks "now on this chapter" as a baseline even before any audio
        // plays — onSentenceChanged takes over with finer-grained positions
        // once playback actually starts.
        ProgressStore.shared.recordLocal(bookID: book.id, chapterIndex: index, sentenceIndex: 0)
        syncProgress()
    }

    /// Lock-screen / remote next-track & previous-track — unlike goTo()
    /// (manual toolbar browsing, which lands on the chapter without
    /// playing), a remote skip command only fires while there's an active
    /// listening session, so it should keep listening into the new chapter
    /// the same way handleChapterFinished's auto-next does. Falls back to
    /// goTo()'s plain-navigation behavior when nothing was playing.
    private func skipChapter(_ index: Int) {
        guard index >= 0, index < book.n else { return }
        guard playback.isPlaying else {
            goTo(index)
            return
        }
        playback.stop()
        shouldAutoPlayNextChapter = true
        chapter = nil
        chapterIndex = index
        ProgressStore.shared.recordLocal(bookID: book.id, chapterIndex: index, sentenceIndex: 0)
        syncProgress()
    }

    private func togglePlayback() {
        guard let chapter else { return }
        let wasPlaying = playback.isPlaying
        playback.togglePlay(text: chapter.text, baseURL: SessionStore.baseURL)
        if wasPlaying { syncProgress() }
    }

    private func syncProgress() {
        Task { await ProgressStore.shared.syncToServer(bookID: book.id) }
    }

    /// Only ever applies once per ReaderView instance (first chapter load) —
    /// matches "open app -> jump to saved chapter + highlight saved
    /// sentence" without re-jumping every time the user navigates within
    /// the same reading session.
    private func applyResumeIfNeeded(_ chapter: Chapter) {
        guard !hasCheckedResume else { return }
        hasCheckedResume = true
        guard let saved = ProgressStore.shared.localProgress(bookID: book.id), saved.chapterIndex == chapterIndex else {
            return
        }
        playback.prepareResume(text: chapter.text, sentenceIndex: saved.sentenceIndex)
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
            applyResumeIfNeeded(local)
            resumeAutoPlayIfNeeded(local)
            return
        }

        do {
            let fetched = try await APIClient.shared.fetchChapter(
                baseURL: SessionStore.baseURL, bookID: book.id, index: chapterIndex
            )
            chapter = fetched
            playback.player.updateNowPlaying(bookTitle: book.title, chapterTitle: fetched.title)
            applyResumeIfNeeded(fetched)
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
    .environmentObject(NetworkMonitor.shared)
}
