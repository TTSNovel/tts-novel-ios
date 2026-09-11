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
                    modelSection
                    readingSpeedSection
                    fontSizeSection
                    translationSection
                    automaticSection
                    preloadSection
                    linksSection
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
            .navigationTitle("Reader Settings")
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

    @ViewBuilder
    private var modelSection: some View {
        sectionHeader("Model")
        SettingsRow {
            Picker("Model", selection: $playback.voice) {
                ForEach(TTSVoice.allCases) { voice in
                    Text(voice.displayName).tag(voice)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            // .menu tints the selected-value text + chevron with the app's
            // accent color (blue) by default — .tint here overrides that so
            // it reads as a plain secondary-gray value, matching every
            // other row on this screen.
            .tint(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("modelPicker")
        }

        // vieNeuOfflineV2/V3 currently have more than one selectable
        // speaker preset (see VieNeuOfflineV2Voice) — every other model has
        // a single fixed voice, so this row only shows up once there's an
        // actual choice to make.
        if playback.voice == .vieNeuOfflineV2 {
            sectionHeader("Voice")
            SettingsRow {
                Picker("Voice", selection: $playback.vieNeuOfflineV2Voice) {
                    ForEach(VieNeuOfflineV2Voice.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("vieNeuOfflineV2VoicePicker")
            }
        }

        if playback.voice == .vieNeuOfflineV3 {
            sectionHeader("Voice")
            SettingsRow {
                Picker("Voice", selection: $playback.vieNeuOfflineV3Voice) {
                    ForEach(VieNeuOfflineV3Voice.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("vieNeuOfflineV3VoicePicker")
            }
        }

        // gwen_tts's 9 built-in reference speakers (see GwenTTSSpeaker) —
        // same pattern as vieNeuOfflineV2 above.
        if playback.voice == .gwenTTS {
            sectionHeader("Voice")
            SettingsRow {
                Picker("Voice", selection: $playback.gwenTTSSpeaker) {
                    ForEach(GwenTTSSpeaker.allCases) { speaker in
                        Text(speaker.displayName).tag(speaker)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("gwenTTSSpeakerPicker")
            }
        }
    }

    private var readingSpeedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Reading Speed")
            SettingsRow {
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

    private var fontSizeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Font Size")
            SettingsRow {
                // Tried a Stepper here first (auto-disables at bounds, lays
                // out fine) — but its arrows are a tiny ~20pt hit target,
                // fiddly to click. A segmented Picker — the same control
                // "Reading Speed" above already uses — gives every value
                // its own full-height tappable segment instead.
                Picker("Font Size", selection: $playback.fontScale) {
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

    private var translationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Translation")
            SettingsRow(label: "Primary language") {
                Picker("Primary language", selection: $playback.primaryLanguageCode) {
                    ForEach(PrimaryLanguageOption.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.secondary)
                .accessibilityIdentifier("primaryLanguagePicker")
            }
            Divider()
            SettingsRow(label: "Engine") {
                Picker("Engine", selection: $playback.translationEngineKind) {
                    ForEach(TranslationEngineKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.secondary)
                .accessibilityIdentifier("translationEnginePicker")
            }
            Divider()
            SettingsRow(label: "Auto-translate") {
                Toggle("Auto-translate", isOn: $playback.autoTranslate)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("autoTranslateToggle")
            }
        }
    }

    @ViewBuilder
    private var automaticSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Automatic")
            SettingsRow(label: "Auto-advance to next chapter") {
                Toggle("Auto-advance to next chapter", isOn: $playback.autoNextChapter)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Divider()
            SettingsRow(label: "Sleep timer") {
                Picker("Sleep timer", selection: $playback.autoStopMinutes) {
                    Text("Off").tag(0.0)
                    ForEach([5.0, 15.0, 30.0, 45.0, 60.0, 90.0, 120.0], id: \.self) { minutes in
                        Text("\(Int(minutes)) min").tag(minutes)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.secondary)
            }
            // See PlaybackBar's matching countdown for why
            // "deadline > Date()" guards Text(timerInterval:).
            if let deadline = playback.sleepTimerDeadline, deadline > Date() {
                Divider()
                SettingsRow(label: "Turns off in") {
                    Text(timerInterval: Date()...deadline, countsDown: true)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var preloadSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Preload")
            SettingsRow(label: "Sentences to preload") {
                Picker("Sentences to preload", selection: $playback.preloadAhead) {
                    ForEach([3, 5, 10, 15, 20], id: \.self) { n in
                        Text("\(n) sentences").tag(n)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.secondary)
            }
            sectionFooter("How many sentences' audio to buffer ahead of the playhead — smoother playback, but uses more bandwidth.")
        }
    }

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                FilterWordsView()
            } label: {
                SettingsLinkRow(icon: "line.3.horizontal.decrease.circle", label: "Filter Words")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("filterWordsLink")
            Divider()
            Button {
                showingBugReport = true
            } label: {
                SettingsLinkRow(icon: "ladybug", label: "Report a Bug", showsChevron: false)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("bugReportLink")
            Divider()
        }
        .padding(.top, 14)
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if session.isLoggedIn {
                Button {
                    isPresented = false
                    session.logout()
                } label: {
                    Text("Log Out")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            .padding(.top, 14)
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

// A row with an optional leading label and a trailing control — when
// `label` is nil, `content` fills the row's full width instead of being
// pushed to the trailing edge, so bare pickers (Model, Reading Speed, Font
// Size, Preload) read as a full-width control rather than a tiny floating
// dropdown.
private struct SettingsRow<Content: View>: View {
    var label: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            if let label {
                Text(label)
                    .font(.system(size: 13.5))
                Spacer(minLength: 8)
            }
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
