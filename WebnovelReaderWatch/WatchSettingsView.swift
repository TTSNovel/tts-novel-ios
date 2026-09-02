import SwiftUI
import Core

/// Watch's settings screen — same shape as iOS's `ReaderSettingsSheet`
/// minus the Translation section (neither translation engine is available
/// on watchOS — no watchOS onnxruntime product for OPUS-MT, no watchOS
/// support in Apple's Translation framework for the other). Everything
/// else (voice, speed, sleep timer, auto-advance, preload, history, bug
/// report, login/logout) is real parity, reusing `ActionHistoryView`/
/// `BugReportView`/`LoginView` directly.
struct WatchSettingsView: View {
    @EnvironmentObject private var playback: WatchPlaybackController
    @EnvironmentObject private var session: SessionStore
    @Binding var isPresented: Bool
    @State private var showingBugReport = false
    @State private var showingLogin = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Giọng đọc") {
                    Picker("Giọng đọc", selection: $playback.voice) {
                        ForEach(WatchPlaybackController.availableVoices) { voice in
                            Text(voice.displayName).tag(voice)
                        }
                    }
                    .accessibilityIdentifier("voicePicker")
                }

                if playback.voice == .gwenTTS {
                    Section("Giọng") {
                        Picker("Giọng", selection: $playback.gwenTTSSpeaker) {
                            ForEach(GwenTTSSpeaker.allCases) { speaker in
                                Text(speaker.displayName).tag(speaker)
                            }
                        }
                        .accessibilityIdentifier("gwenSpeakerPicker")
                    }
                }

                Section("Tốc độ đọc") {
                    Picker("Tốc độ", selection: $playback.speed) {
                        ForEach([0.85, 1.0, 1.15, 1.3, 1.5], id: \.self) { speed in
                            Text("\(speed, specifier: "%.2g")x").tag(speed)
                        }
                    }
                    .accessibilityIdentifier("speedPicker")
                }

                Section("Tự động") {
                    Toggle("Tự chuyển chương tiếp theo", isOn: $playback.autoNextChapter)
                        .accessibilityIdentifier("autoNextToggle")
                    Picker("Hẹn giờ tắt", selection: $playback.autoStopMinutes) {
                        Text("Tắt").tag(0.0)
                        ForEach([5.0, 15.0, 30.0, 45.0, 60.0], id: \.self) { minutes in
                            Text("\(Int(minutes)) phút").tag(minutes)
                        }
                    }
                    .accessibilityIdentifier("sleepTimerPicker")
                    if let deadline = playback.sleepTimerDeadline, deadline > Date() {
                        HStack {
                            Text("Còn lại")
                            Spacer()
                            Text(timerInterval: Date()...deadline, countsDown: true)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .accessibilityIdentifier("sleepTimerCountdown")
                    }
                    Picker("Số câu tải trước", selection: $playback.preloadAhead) {
                        ForEach([2, 5, 10], id: \.self) { n in
                            Text("\(n) câu").tag(n)
                        }
                    }
                    .accessibilityIdentifier("preloadPicker")
                }

                Section {
                    NavigationLink {
                        ActionHistoryView()
                    } label: {
                        Label("Nhật ký", systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("historyLink")
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
                            session.logout()
                        }
                        .accessibilityIdentifier("logoutButton")
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
                        Text("Đăng nhập trên iPhone để tự động đồng bộ sang Watch, hoặc đăng nhập trực tiếp tại đây.")
                    }
                }
            }
            .navigationTitle("Cài đặt")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { isPresented = false }
                        .accessibilityIdentifier("settingsDoneButton")
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
