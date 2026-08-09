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

    var body: some View {
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
                    Button("Đăng xuất", role: .destructive) {
                        isPresented = false
                        session.logout()
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
        }
    }
}

#Preview {
    ReaderSettingsSheet(isPresented: .constant(true))
        .environmentObject(ReaderPlaybackController.shared)
        .environmentObject(SessionStore.shared)
}
