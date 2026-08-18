import SwiftUI

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
                    // (e.g. "Hẹn giờ tắt").
                    .tint(.secondary)
                    .accessibilityIdentifier("modelPicker")
                }

                // Only vieNeuOffline currently has more than one selectable
                // speaker preset (see VieNeuOfflineVoice) — every other
                // model has a single fixed voice, so this section only
                // shows up once there's an actual choice to make.
                if playback.voice == .vieNeuOffline {
                    Section("Giọng đọc") {
                        Picker("Giọng đọc", selection: $playback.vieNeuOfflineVoice) {
                            ForEach(VieNeuOfflineVoice.allCases) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.secondary)
                        .accessibilityIdentifier("vieNeuOfflineVoicePicker")
                    }
                }

                // gwen_tts's 9 built-in reference speakers (see
                // GwenTTSSpeaker) — same pattern as vieNeuOffline above.
                if playback.voice == .gwenTTS {
                    Section("Giọng đọc") {
                        Picker("Giọng đọc", selection: $playback.gwenTTSSpeaker) {
                            ForEach(GwenTTSSpeaker.allCases) { speaker in
                                Text(speaker.displayName).tag(speaker)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.secondary)
                        .accessibilityIdentifier("gwenTTSSpeakerPicker")
                    }
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
                        ForEach([5.0, 15.0, 30.0, 45.0, 60.0, 90.0, 120.0], id: \.self) { minutes in
                            Text("\(Int(minutes)) phút").tag(minutes)
                        }
                    }
                    // See PlaybackBar's matching countdown for why
                    // "deadline > Date()" guards Text(timerInterval:).
                    if let deadline = playback.sleepTimerDeadline, deadline > Date() {
                        HStack {
                            Text("Sẽ tắt sau")
                            Spacer()
                            Text(timerInterval: Date()...deadline, countsDown: true)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                Section {
                    Picker("Số câu tải trước", selection: $playback.preloadAhead) {
                        ForEach([3, 5, 10, 15, 20], id: \.self) { n in
                            Text("\(n) câu").tag(n)
                        }
                    }
                } header: {
                    Text("Tải trước")
                } footer: {
                    Text("Số câu audio được tải sẵn trước khi đọc tới, giúp đọc liền mạch hơn nhưng tốn băng thông hơn.")
                }

                Section {
                    NavigationLink {
                        ActionHistoryView()
                    } label: {
                        Label("Nhật ký & lịch sử", systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("actionHistoryLink")

                    Button {
                        showingBugReport = true
                    } label: {
                        Label("Báo lỗi", systemImage: "ladybug")
                    }
                    .accessibilityIdentifier("bugReportLink")
                }

                Section {
                    if session.isLoggedIn {
                        Button("Đăng xuất", role: .destructive) {
                            isPresented = false
                            session.logout()
                        }
                    } else {
                        Button {
                            showingLogin = true
                        } label: {
                            Label("Đăng nhập", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .accessibilityIdentifier("settingsLoginButton")
                    }
                } footer: {
                    if !session.isLoggedIn {
                        Text("Đang dùng ở chế độ khách — đăng nhập để nghe giọng đọc online và đồng bộ tiến độ đọc giữa các thiết bị.")
                    }
                }
            }
            .navigationTitle("Cài đặt đọc")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { isPresented = false }
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
