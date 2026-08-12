"""Single source of truth for the Kiwi test-case catalog: one entry per
XCUITest method (automated) plus the one case that can't be automated
(lock-screen/Control Center now-playing UI is outside the app process).

`key` is "ClassName.testMethodName", matching what report_results.py reads
out of the .xcresult bundle — that's how a test result gets matched back to
its Kiwi case.
"""

CASES = [
    {
        "key": "LoginFlowUITests.testGuestLandsDirectlyOnLibraryWithoutLogin",
        "summary": "Guest mode lands directly on Library without requiring login",
        "steps": "1. Launch app fresh.\n2. Expect Library screen immediately, no login prompt.",
        "automated": True,
    },
    {
        "key": "LoginFlowUITests.testLoginFromSettingsShowsLoggedInState",
        "summary": "Logging in from Settings shows logged-in state (Đăng xuất)",
        "steps": "1. Open Settings sheet.\n2. Tap Đăng nhập, enter credentials, submit.\n3. Expect Đăng xuất button to appear.",
        "automated": True,
    },
    {
        "key": "BookDetailActionsUITests.testStartAndContinueButtonsNavigateToReader",
        "summary": "BookDetail 'Đọc từ đầu'/'Đọc tiếp' buttons are tappable and open the Reader",
        "steps": "1. Tap a book row in Library.\n2. Expect Đọc từ đầu button, tap size >= 24pt.\n3. Tap it, expect ReaderView (playPauseButton visible).",
        "automated": True,
    },
    {
        "key": "ChapterListUITests.testChapterListSheetAndBookDetailShowRealTitles",
        "summary": "Chapter list (BookDetail section + Reader popup) shows real chapter titles, not placeholders",
        "steps": "1. Open a book's detail page — chapter rows should contain ':' (real title).\n2. Open Reader, tap chapter-list button.\n3. Chapter sheet rows should also show real titles.",
        "automated": True,
    },
    {
        "key": "ResumeFlowUITests.testLaunchResumesAtSavedSentence",
        "summary": "App launch resumes at the saved sentence, not sentence 1",
        "steps": "1. Seed server-side progress mid-chapter for the most-recently-read book.\n2. Launch app.\n3. Expect direct navigation into ReaderView at the saved sentence.\n4. Press Play — should continue from that sentence.",
        "automated": True,
    },
    {
        "key": "ResumeFlowUITests.testSettingsSheetShowsAllControls",
        "summary": "Settings sheet exposes voice picker, auto-next toggle, and sleep timer control",
        "steps": "1. Open Settings sheet.\n2. Expect voice options, an auto-next switch, and the 'Hẹn giờ tắt' sleep-timer row.",
        "automated": True,
    },
    {
        "key": "OfflineDownloadUITests.testDownloadFirstBook",
        "summary": "Downloading a book from BookDetail completes and flips to the delete-download state",
        "steps": "1. Open a book's detail page.\n2. Tap Download.\n3. Wait for it to complete (delete button appears).",
        "automated": True,
    },
    {
        "key": "PlaybackPersistenceUITests.testPlaybackSurvivesNavigatingBackToLibrary",
        "summary": "Playback keeps running when navigating back to Library mid-chapter",
        "steps": "1. Start playback in Reader.\n2. Navigate back to Library.\n3. Expect PlaybackBar still visible/playing.",
        "automated": True,
    },
    {
        "key": "SettingsAndPlaybarLayoutUITests.testLogoutButtonLivesInSettingsSheet",
        "summary": "Logout button lives inside the Settings sheet, not scattered elsewhere",
        "steps": "1. Log in.\n2. Open Settings sheet.\n3. Expect Đăng xuất button present inside the sheet.",
        "automated": True,
    },
    {
        "key": "SettingsAndPlaybarLayoutUITests.testReaderContentNotCoveredByPlaybackBar",
        "summary": "Reader content isn't visually covered by the persistent PlaybackBar",
        "steps": "1. Open Reader with playback active.\n2. Expect chapter content to end above the PlaybackBar's frame, not underneath it.",
        "automated": True,
    },
    {
        "key": "TTSPlaybackUITests.testPlayAudioForEveryVoice",
        "summary": "Play button works for every TTS voice option",
        "steps": "1. For each voice in the picker: select it, tap Play, expect isPlaying state and audio progress.",
        "automated": True,
    },
    {
        "key": "BugReportAndHistoryUITests.testActionHistoryReachableAndFiltersable",
        "summary": "Action History screen is reachable from Settings and supports filtering by event type",
        "steps": "1. Log in.\n2. Settings -> Nhật ký & lịch sử.\n3. Expect at least one navigation event logged.\n4. Filter to 'Điều hướng' -> entry still visible.",
        "automated": True,
    },
    {
        "key": "BugReportAndHistoryUITests.testBugReportAllowsEmptyDescriptionAndSubmits",
        "summary": "Bug report can be submitted with an empty description (log attaches automatically)",
        "steps": "1. Log in.\n2. Settings -> Báo lỗi.\n3. Submit with no description typed.\n4. Expect success alert or a visible failure message (not a hang).",
        "automated": True,
    },
    {
        "key": "LibraryUITests.testLibraryShowsBooksAndOpensDownloadedList",
        "summary": "Library shows book rows and its toolbar button opens Downloaded Books",
        "steps": "1. Launch app, land on Library.\n2. Expect at least one book row.\n3. Tap the Downloaded Books toolbar button.\n4. Expect the Đã tải xuống screen.",
        "automated": True,
    },
    {
        "key": "DownloadedBooksUITests.testDownloadedListShowsEmptyStateOrDownloadedBook",
        "summary": "Downloaded Books screen shows either the empty state or a real downloaded row, and rows navigate to BookDetail",
        "steps": "1. Library -> Downloaded Books.\n2. Expect empty-state message or a book row.\n3. If a row exists, tap it and expect BookDetailView.",
        "automated": True,
    },
    {
        "key": "HistoryUITests.testSeeAllHistoryOpensFullListAndNavigatesBackIntoBook",
        "summary": "Reading History (Xem tất cả) lists recently-read books and rows navigate back into them",
        "steps": "1. Open a chapter to generate progress.\n2. Back out to Library, tap Xem tất cả.\n3. Expect Lịch sử đọc screen listing the book.\n4. Tap it, expect BookDetailView.",
        "automated": True,
    },
    {
        "key": "SleepTimerUITests.testSettingSleepTimerShowsCountdown",
        "summary": "Setting a sleep timer duration shows a running countdown in Settings and on the PlaybackBar",
        "steps": "1. Open Reader with playback.\n2. Settings -> Hẹn giờ tắt -> pick 30 phút.\n3. Expect 'Sẽ tắt sau' countdown in the sheet.\n4. Close sheet — expect countdown on PlaybackBar too.",
        "automated": True,
    },
    {
        "key": "ChapterNavigationUITests.testNextAndPreviousChapterButtonsChangeChapter",
        "summary": "PlaybackBar's prev/next-chapter buttons move between chapters and update the displayed chapter number",
        "steps": "1. Open Reader on chapter 1.\n2. Tap next-chapter -> expect chapter number increments.\n3. Tap previous-chapter -> expect it returns to chapter 1.",
        "automated": True,
    },
    {
        "key": "manual.LockScreenNowPlayingProgress",
        "summary": "[MANUAL] Lock screen / Control Center shows now-playing progress bar and responds to skip commands",
        "steps": (
            "1. Start playback, lock the device (or Control Center on Simulator).\n"
            "2. Expect the now-playing card to show title, chapter, and an "
            "estimated progress bar.\n"
            "3. Tap next/previous track from the lock screen.\n"
            "4. Expect the app to skip chapters accordingly when reopened."
        ),
        "automated": False,
    },
]
