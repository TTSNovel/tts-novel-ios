import SwiftUI
import Core

// Extracted out of ReaderView so PlaybackBar (now the only place the
// settings gear lives — see its doc comment) can present the exact same
// sheet from every screen, not just while looking at a chapter. Everything
// here reads/writes ReaderPlaybackController.shared directly, so it has no
// dependency on which screen presented it.
struct ReaderSettingsSheet: View {
    @EnvironmentObject private var playback: ReaderPlaybackController
    @EnvironmentObject private var session: SessionStore
    @Binding var isPresented: Bool
    @State private var showingBugReport = false
    @State private var showingLogin = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    Picker("Model", selection: $playback.voice) {
                        ForEach(TTSVoice.allCases) { voice in
                            Text(voice.displayName).tag(voice)
                        }
                    }
                    .pickerStyle(.menu)
                    // .menu tints the selected-value text + chevron with
                    // the app's accent color (blue) by default — .tint
                    // here overrides that so it reads as a plain secondary-
                    // gray value, matching every other row in this Form
                    // (e.g. "Sleep timer").
                    .tint(.secondary)
                    .accessibilityIdentifier("modelPicker")
                }

                // vieNeuOfflineV2/V3 currently have more than one selectable
                // speaker preset (see VieNeuOfflineV2Voice) — every other
                // model has a single fixed voice, so this section only
                // shows up once there's an actual choice to make.
                if playback.voice == .vieNeuOfflineV2 {
                    Section("Voice") {
                        Picker("Voice", selection: $playback.vieNeuOfflineV2Voice) {
                            ForEach(VieNeuOfflineV2Voice.allCases) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.secondary)
                        .accessibilityIdentifier("vieNeuOfflineV2VoicePicker")
                    }
                }

                if playback.voice == .vieNeuOfflineV3 {
                    Section("Voice") {
                        Picker("Voice", selection: $playback.vieNeuOfflineV3Voice) {
                            ForEach(VieNeuOfflineV3Voice.allCases) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.secondary)
                        .accessibilityIdentifier("vieNeuOfflineV3VoicePicker")
                    }
                }

                // gwen_tts's 9 built-in reference speakers (see
                // GwenTTSSpeaker) — same pattern as vieNeuOfflineV2 above.
                if playback.voice == .gwenTTS {
                    Section("Voice") {
                        Picker("Voice", selection: $playback.gwenTTSSpeaker) {
                            ForEach(GwenTTSSpeaker.allCases) { speaker in
                                Text(speaker.displayName).tag(speaker)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.secondary)
                        .accessibilityIdentifier("gwenTTSSpeakerPicker")
                    }
                }

                Section("Reading Speed") {
                    Picker("Speed", selection: $playback.speed) {
                        ForEach([0.85, 1.0, 1.15, 1.3, 1.5], id: \.self) { speed in
                            Text("\(speed, specifier: "%.2g")x").tag(speed)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Font Size") {
                    // Tried a Stepper here first (auto-disables at bounds,
                    // Form lays it out fine) — but its arrows are a tiny
                    // ~20pt hit target, fiddly to click. A segmented Picker
                    // — the same control "Reading Speed" above already
                    // uses — gives every value its own full-height tappable
                    // segment instead.
                    Picker("Font Size", selection: $playback.fontScale) {
                        ForEach(ReaderPlaybackController.fontScaleSteps, id: \.self) { scale in
                            Text("\(Int((scale * 100).rounded()))%").tag(scale)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("fontSizePicker")
                }

                Section("Translation") {
                    Picker("Primary language", selection: $playback.primaryLanguageCode) {
                        ForEach(PrimaryLanguageOption.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.secondary)
                    .accessibilityIdentifier("primaryLanguagePicker")

                    Picker("Engine", selection: $playback.translationEngineKind) {
                        ForEach(TranslationEngineKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.secondary)
                    .accessibilityIdentifier("translationEnginePicker")

                    Toggle("Auto-translate", isOn: $playback.autoTranslate)
                        .accessibilityIdentifier("autoTranslateToggle")
                }

                Section("Automatic") {
                    Toggle("Auto-advance to next chapter", isOn: $playback.autoNextChapter)
                    Picker("Sleep timer", selection: $playback.autoStopMinutes) {
                        Text("Off").tag(0.0)
                        ForEach([5.0, 15.0, 30.0, 45.0, 60.0, 90.0, 120.0], id: \.self) { minutes in
                            Text("\(Int(minutes)) min").tag(minutes)
                        }
                    }
                    // See PlaybackBar's matching countdown for why
                    // "deadline > Date()" guards Text(timerInterval:).
                    if let deadline = playback.sleepTimerDeadline, deadline > Date() {
                        HStack {
                            Text("Turns off in")
                            Spacer()
                            Text(timerInterval: Date()...deadline, countsDown: true)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                Section {
                    Picker("Sentences to preload", selection: $playback.preloadAhead) {
                        ForEach([3, 5, 10, 15, 20], id: \.self) { n in
                            Text("\(n) sentences").tag(n)
                        }
                    }
                } header: {
                    Text("Preload")
                } footer: {
                    Text("How many sentences' audio to buffer ahead of the playhead — smoother playback, but uses more bandwidth.")
                }

                Section {
                    NavigationLink {
                        ActionHistoryView()
                    } label: {
                        Label("History & Log", systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("actionHistoryLink")

                    Button {
                        showingBugReport = true
                    } label: {
                        Label("Report a Bug", systemImage: "ladybug")
                    }
                    .accessibilityIdentifier("bugReportLink")
                }

                Section {
                    if session.isLoggedIn {
                        Button("Log Out", role: .destructive) {
                            isPresented = false
                            session.logout()
                        }
                    } else {
                        Button {
                            showingLogin = true
                        } label: {
                            Label("Log In", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .accessibilityIdentifier("settingsLoginButton")
                    }
                } footer: {
                    if !session.isLoggedIn {
                        Text("You're browsing as a guest — log in to use online voices and sync reading progress across devices.")
                    }
                }
            }
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
    }
}

#Preview {
    ReaderSettingsSheet(isPresented: .constant(true))
        .environmentObject(ReaderPlaybackController.shared)
        .environmentObject(SessionStore.shared)
        .environmentObject(EventLogStore.shared)
}
