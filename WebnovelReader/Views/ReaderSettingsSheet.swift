import SwiftUI
import Core

// Extracted out of ReaderView so PlaybackBar (now the only place the
// settings gear lives — see its doc comment) can present the exact same
// sheet from every screen, not just while looking at a chapter. Everything
// here reads/writes ReaderPlaybackController.shared directly, so it has no
// dependency on which screen presented it.
//
// Rows are plain ScrollView+VStack, not `Form` — `Form`'s default macOS
// style put each row's label in a wide right-aligned left column (native
// System-Settings look), which visually duplicated the section header right
// above it (e.g. a "Model" header sitting directly over a row *also*
// labeled "Model"). This mirrors the flat/dark row style FilterWordsView
// already uses: uppercase tracked section labels, a single-column row with
// an optional leading label + trailing control, divider lines between rows.
// There's no separate design mockup for this screen (unlike FilterWords) —
// the paddings/font sizes below are carried over from FilterWordsView's
// mockup-derived numbers for visual consistency, not from a new mockup.
//
// This view is the ROOT of its own NavigationStack (presented via
// `.sheet`), not a pushed destination — so it does NOT need FilterWordsView's
// `macNavigationStackLeadingOverflow` offset hack, which only applies to
// content *pushed* inside that NavigationStack (like FilterWordsView
// itself). Its own `.toolbar` "Done" button is likewise unaffected by the
// bottom-bar-overlap bug documented on FilterWordsView, since that bug is
// specific to pushed destinations too.
//
// Layout is grouped by what the reader is trying to do, most-used first:
// LISTEN (which voice reads the chapter, its speaker, speed), TRANSLATE
// (which translator, into what, glossary), READING (font size), PLAYBACK
// (auto-advance, sleep timer, preload), then tools and account. The two
// pickers people actually come here for — the TTS voice and the
// translator — used to be a bare unlabeled "Model" dropdown and an
// "Engine" row buried mid-sheet; they now lead their sections as labeled
// rows with an icon and a one-line description of the current choice, and
// their menus group options into Online / On-device.
struct ReaderSettingsSheet: View {
    @EnvironmentObject private var playback: ReaderPlaybackController
    @EnvironmentObject private var session: SessionStore
    @Binding var isPresented: Bool
    @State private var showingBugReport = false
    @State private var showingLogin = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    listenSection
                    translateSection
                    readingSection
                    playbackSection
                    toolsSection
                    accountSection
                }
            }
            #if os(macOS)
            // Same reasoning as FilterWordsView's matching inset: the
            // "Done" toolbar button is real AppKit window chrome that
            // floats over the bottom-right corner instead of reserving
            // layout space, so give the last row room to scroll clear of it.
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 44)
            }
            #endif
            .navigationTitle("Settings")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
            .sheet(isPresented: $showingBugReport) {
                BugReportView(isPresented: $showingBugReport)
            }
            .sheet(isPresented: $showingLogin) {
                LoginView(isPresented: $showingLogin)
            }
        }
        #if os(macOS)
        // Without this, macOS sizes the sheet to the ideal size of
        // whichever NavigationStack destination is currently showing — the
        // root content reports a real ideal size, but a pushed `List`-based
        // destination (e.g. ActionHistoryView) reports one so small the
        // sheet collapses to just its title bar/toolbar, with the List
        // content clipped to nothing. A fixed frame here keeps the sheet's
        // size stable across every push instead of re-fitting to each
        // destination.
        .frame(minWidth: 480, idealWidth: 560, minHeight: 480, idealHeight: 720)
        #endif
    }

    // MARK: - Sections

    private var listenSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Listen")
            SettingsRow(icon: "waveform", label: "Reading voice", detail: playback.voice.settingsDetail) {
                Picker("Reading voice", selection: $playback.voice) {
                    Section("Online") {
                        ForEach(TTSVoice.allCases.filter { !$0.isOffline }) { voice in
                            Text(voice.displayName).tag(voice)
                        }
                    }
                    Section("On this device") {
                        ForEach(TTSVoice.allCases.filter(\.isOffline)) { voice in
                            Text(voice.displayName).tag(voice)
                        }
                    }
                }
                .settingsMenuPicker()
                .accessibilityIdentifier("modelPicker")
            }
            speakerRow
            Divider()
            SettingsRow(icon: "speedometer", label: "Speed", stacked: true) {
                Picker("Speed", selection: $playback.speed) {
                    ForEach([0.85, 1.0, 1.15, 1.3, 1.5], id: \.self) { speed in
                        Text("\(speed, specifier: "%.2g")x").tag(speed)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }
    }

    // vieNeuOfflineV2/V3 and gwen_tts have more than one selectable
    // speaker preset (see VieNeuOfflineV2Voice/GwenTTSSpeaker) — every
    // other voice has a single fixed speaker, so this row only shows up
    // once there's an actual choice to make.
    @ViewBuilder
    private var speakerRow: some View {
        switch playback.voice {
        case .vieNeuOfflineV2:
            Divider()
            SettingsRow(icon: "person.wave.2", label: "Speaker") {
                Picker("Speaker", selection: $playback.vieNeuOfflineV2Voice) {
                    ForEach(VieNeuOfflineV2Voice.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .settingsMenuPicker()
                .accessibilityIdentifier("vieNeuOfflineV2VoicePicker")
            }
        case .vieNeuOfflineV3:
            Divider()
            SettingsRow(icon: "person.wave.2", label: "Speaker") {
                Picker("Speaker", selection: $playback.vieNeuOfflineV3Voice) {
                    ForEach(VieNeuOfflineV3Voice.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .settingsMenuPicker()
                .accessibilityIdentifier("vieNeuOfflineV3VoicePicker")
            }
        case .gwenTTS:
            Divider()
            SettingsRow(icon: "person.wave.2", label: "Speaker") {
                Picker("Speaker", selection: $playback.gwenTTSSpeaker) {
                    ForEach(GwenTTSSpeaker.allCases) { speaker in
                        Text(speaker.displayName).tag(speaker)
                    }
                }
                .settingsMenuPicker()
                .accessibilityIdentifier("gwenTTSSpeakerPicker")
            }
        default:
            EmptyView()
        }
    }

    private var translateSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Translate")
            SettingsRow(icon: "character.bubble", label: "Translator", detail: playback.translationEngineKind.settingsDetail) {
                Picker("Translator", selection: $playback.translationEngineKind) {
                    Section("On this device") {
                        ForEach(TranslationEngineKind.allCases.filter { !$0.isOnline }) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    Section("Online") {
                        ForEach(TranslationEngineKind.allCases.filter(\.isOnline)) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                }
                .settingsMenuPicker()
                .accessibilityIdentifier("translationEnginePicker")
            }
            Divider()
            SettingsRow(icon: "globe", label: "Translate into") {
                Picker("Translate into", selection: $playback.primaryLanguageCode) {
                    ForEach(PrimaryLanguageOption.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .settingsMenuPicker()
                .accessibilityIdentifier("primaryLanguagePicker")
            }
            Divider()
            SettingsRow(icon: "wand.and.stars", label: "Auto-translate chapters") {
                Toggle("Auto-translate chapters", isOn: $playback.autoTranslate)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("autoTranslateToggle")
            }
            if [.google, .apple].contains(playback.translationEngineKind), let book = playback.book {
                Divider()
                NavigationLink {
                    GlossaryView(bookID: book.id)
                } label: {
                    SettingsLinkRow(icon: "character.book.closed", label: "Glossary")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("glossaryLink")
                if playback.translationEngineKind == .google {
                    Divider()
                    StoredTranslationsRow(bookID: book.id)
                }
            }
        }
    }

    private var readingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Reading")
            SettingsRow(icon: "textformat.size", label: "Font size", stacked: true) {
                // Tried a Stepper here first (auto-disables at bounds, lays
                // out fine) — but its arrows are a tiny ~20pt hit target,
                // fiddly to click. A segmented Picker — the same control
                // "Speed" above already uses — gives every value its own
                // full-height tappable segment instead.
                Picker("Font size", selection: $playback.fontScale) {
                    ForEach(ReaderPlaybackController.fontScaleSteps, id: \.self) { scale in
                        Text("\(Int((scale * 100).rounded()))%").tag(scale)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityIdentifier("fontSizePicker")
            }
        }
    }

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Playback")
            SettingsRow(icon: "forward.end", label: "Auto-advance to next chapter") {
                Toggle("Auto-advance to next chapter", isOn: $playback.autoNextChapter)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Divider()
            SettingsRow(icon: "moon.zzz", label: "Sleep timer") {
                Picker("Sleep timer", selection: $playback.autoStopMinutes) {
                    Text("Off").tag(0.0)
                    ForEach([5.0, 15.0, 30.0, 45.0, 60.0, 90.0, 120.0], id: \.self) { minutes in
                        Text("\(Int(minutes)) min").tag(minutes)
                    }
                }
                .settingsMenuPicker()
            }
            // See PlaybackBar's matching countdown for why
            // "deadline > Date()" guards Text(timerInterval:).
            if let deadline = playback.sleepTimerDeadline, deadline > Date() {
                Divider()
                SettingsRow(icon: "timer", label: "Turns off in") {
                    Text(timerInterval: Date()...deadline, countsDown: true)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Divider()
            SettingsRow(
                icon: "square.stack.3d.down.right",
                label: "Preload audio",
                detail: "Sentences buffered ahead of the playhead — smoother playback, more bandwidth."
            ) {
                Picker("Preload audio", selection: $playback.preloadAhead) {
                    ForEach([3, 5, 10, 15, 20], id: \.self) { n in
                        Text("\(n) sentences").tag(n)
                    }
                }
                .settingsMenuPicker()
            }
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Tools")
            NavigationLink {
                FilterWordsView()
            } label: {
                SettingsLinkRow(icon: "line.3.horizontal.decrease.circle", label: "Filter Words")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("filterWordsLink")
            Divider()
            NavigationLink {
                ActionHistoryView()
            } label: {
                SettingsLinkRow(icon: "clock.arrow.circlepath", label: "History & Log")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("actionHistoryLink")
            Divider()
            NavigationLink {
                AudioStorageView()
            } label: {
                SettingsLinkRow(icon: "waveform", label: "Downloaded Audio")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("audioStorageLink")
            Divider()
            Button {
                showingBugReport = true
            } label: {
                SettingsLinkRow(icon: "ladybug", label: "Report a Bug", showsChevron: false)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("bugReportLink")
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Account")
            if session.isLoggedIn {
                Button {
                    isPresented = false
                    session.logout()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 13))
                            .frame(width: 20)
                        Text("Log Out")
                            .font(.system(size: 13.5))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    showingLogin = true
                } label: {
                    SettingsLinkRow(icon: "person.crop.circle.badge.checkmark", label: "Log In", showsChevron: false)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settingsLoginButton")
                sectionFooter("You're browsing as a guest — log in to use online voices and sync reading progress across devices.")
            }
        }
    }

    // MARK: - Row building blocks

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.4)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }

    private func sectionFooter(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 14)
    }
}

// UI copy for the two headline pickers — kept here rather than on the Core
// enums since it's Settings-sheet wording, not model data.
private extension TTSVoice {
    var settingsDetail: String {
        switch self {
        case .piperVi: return "Online · fast, lightweight server voice. Needs login."
        case .googleTTS: return "Online · Google Cloud's natural voice. Needs login."
        case .vieNeu: return "Online · expressive Vietnamese, handles mixed English. Needs login."
        case .gwenTTS: return "Online · cloned speakers, highest quality but slow (10–90 s per sentence). Needs login."
        case .piperOffline: return "On this device · works without internet, light on battery."
        case .vieNeuOfflineV2: return "On this device · VieNeu v2, no internet needed, heavier on battery."
        case .vieNeuOfflineV3: return "On this device · same VieNeu v3 model as the online voice, heavier on battery."
        }
    }
}

private extension TranslationEngineKind {
    var isOnline: Bool { self == .google }

    var settingsDetail: String {
        switch self {
        case .apple: return "On this device · best quality, needs iOS 18 / macOS 15."
        case .opusMT: return "On this device · small bundled model, English → Vietnamese only."
        case .google: return "Online · supports a per-book glossary; translations are saved on the server."
        case .vietPhrase: return "On this device · Chinese → Hán Việt reading, character by character."
        }
    }
}

private extension View {
    // .menu tints the selected-value text + chevron with the app's accent
    // color (blue) by default — .tint here overrides that so it reads as a
    // plain secondary-gray value, matching every other row on this screen.
    func settingsMenuPicker() -> some View {
        labelsHidden()
            .pickerStyle(.menu)
            .tint(.secondary)
    }
}

// A row with a leading icon + label and a trailing control, plus an
// optional description line underneath (indented to line up with the
// label, full row width so it doesn't fight the trailing picker for room).
// `stacked` puts the control on its own full-width line below the label
// instead — for segmented pickers (Speed, Font size) whose five segments
// don't fit beside a label on a phone-width sheet.
private struct SettingsRow<Content: View>: View {
    var icon: String? = nil
    var label: String? = nil
    var detail: String? = nil
    var stacked = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: stacked ? 8 : 3) {
            if stacked {
                labelView
                content
            } else {
                HStack(spacing: 10) {
                    labelView
                    Spacer(minLength: 8)
                    content
                }
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, icon == nil ? 0 : 30)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var labelView: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
            }
            if let label {
                Text(label)
                    .font(.system(size: 13.5))
            }
        }
    }
}

/// Google translations are stored on the server per chapter (see
/// `GoogleCloudTranslationEngine`) — shows how many chapters of the open
/// book are stored and lets them be deleted, e.g. to re-translate after a
/// glossary edit without waiting for its lazy re-translation.
private struct StoredTranslationsRow: View {
    let bookID: Int
    @State private var chapterCount: Int?
    @State private var failed = false
    @State private var isDeleting = false

    var body: some View {
        SettingsRow(label: "Saved translations") {
            Text(summary)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("storedTranslationsCount")
            Button("Delete", role: .destructive) {
                Task { await delete() }
            }
            .disabled(isDeleting || (chapterCount ?? 0) == 0)
            .accessibilityIdentifier("deleteStoredTranslationsButton")
        }
        .task(id: bookID) { await load() }
    }

    private var summary: String {
        if failed { return "Unavailable" }
        guard let chapterCount else { return "…" }
        return chapterCount == 1 ? "1 chapter" : "\(chapterCount) chapters"
    }

    private func load() async {
        do {
            chapterCount = try await APIClient.shared.fetchStoredTranslationChapterCount(baseURL: SessionStore.baseURL, bookID: bookID)
            failed = false
        } catch {
            failed = true // nolog: APIClient logged the failed request
        }
    }

    private func delete() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await APIClient.shared.deleteStoredTranslations(baseURL: SessionStore.baseURL, bookID: bookID)
        } catch {
            failed = true // nolog: APIClient logged the failed request
            return
        }
        await load()
    }
}

private struct SettingsLinkRow: View {
    let icon: String
    let label: String
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 13.5))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

#Preview {
    ReaderSettingsSheet(isPresented: .constant(true))
        .environmentObject(ReaderPlaybackController.shared)
        .environmentObject(SessionStore.shared)
        .environmentObject(EventLogStore.shared)
}
