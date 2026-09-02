import SwiftUI
#if os(iOS)
import UIKit
#endif
import Core

/// Sends a description + (optionally) the recent EventLogStore timeline to
/// app/server.py's /api/bug-report (tts-webnovel repo) — the same server
/// this app already talks to for everything else, so no separate service to
/// configure. Reached from ReaderSettingsSheet ("Báo lỗi").
struct BugReportView: View {
    @EnvironmentObject private var eventLog: EventLogStore
    @Binding var isPresented: Bool

    @State private var description = ""
    @State private var attachRecentLog = true
    @State private var isSubmitting = false
    @State private var submitError: String?
    @State private var didSubmit = false

    /// Time-based, not count-based — a fixed entry count skews short now
    /// that every auto-advanced sentence during playback logs its own
    /// entry (see ReaderPlaybackController.playCurrentSentence), so a count
    /// cap could mean "the last 200 entries" covers only the last few
    /// minutes of a long listening session instead of the actual recent
    /// window a bug report needs.
    private static let attachedLogWindow: TimeInterval = 2 * 60 * 60
    /// Safety upper bound only, independent of the time window above — just
    /// keeps a pathological case (hours of continuous playback) from
    /// producing an unreasonably large request body.
    private static let attachedEventSafetyCap = 2000

    private var attachedEventCount: Int {
        min(eventLog.entries(since: Date().addingTimeInterval(-Self.attachedLogWindow)).count, Self.attachedEventSafetyCap)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Mô tả lỗi (không bắt buộc)") {
                    // TextEditor doesn't exist on watchOS — a multi-line
                    // TextField (axis: .vertical) is the closest cross-
                    // platform equivalent there.
                    #if os(watchOS)
                    TextField("Mô tả lỗi", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("bugReportDescriptionField")
                    #else
                    TextEditor(text: $description)
                        .frame(minHeight: 120)
                        .accessibilityIdentifier("bugReportDescriptionField")
                    #endif
                }

                Section {
                    Toggle("Đính kèm nhật ký gần đây", isOn: $attachRecentLog)
                        .disabled(eventLog.events.isEmpty)
                } footer: {
                    // Toàn bộ nhật ký (hành động lẫn lỗi) trong 2 giờ gần
                    // nhất — không lọc riêng theo loại, vì đây là nơi duy
                    // nhất ứng dụng ghi log; không có log nào khác tách
                    // biệt để gửi thêm.
                    Text("Gồm toàn bộ nhật ký (\(attachedEventCount) mục) trong 2 giờ gần nhất — cả hành động và lỗi, giúp xác định nguyên nhân nhanh hơn.")
                }

                if let submitError {
                    Section {
                        Text(submitError).foregroundStyle(.red).font(.footnote)
                    }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting { ProgressView() } else { Text("Gửi báo cáo") }
                            Spacer()
                        }
                    }
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("bugReportSubmitButton")
                }
            }
            .navigationTitle("Báo lỗi")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { isPresented = false }
                }
            }
            .alert("Đã gửi báo cáo", isPresented: $didSubmit) {
                Button("OK") { isPresented = false }
            } message: {
                Text("Cảm ơn bạn đã báo lỗi — chúng tôi sẽ xem xét sớm.")
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        submitError = nil
        defer { isSubmitting = false }

        let events = attachRecentLog
            ? Array(eventLog.entries(since: Date().addingTimeInterval(-Self.attachedLogWindow)).prefix(Self.attachedEventSafetyCap))
            : []
        #if os(iOS)
        let device = UIDevice.current
        let deviceLabel = "\(device.model) (\(device.systemName) \(device.systemVersion))"
        let osVersion = device.systemVersion
        #else
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let deviceLabel = "\(ProcessInfo.processInfo.hostName) (macOS \(osVersion))"
        #endif
        do {
            try await APIClient.shared.submitBugReport(
                baseURL: SessionStore.baseURL,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                device: deviceLabel,
                osVersion: osVersion,
                appVersion: Self.appVersionString(),
                events: events
            )
            EventLogStore.shared.record(.navigation, "Đã gửi báo cáo lỗi")
            didSubmit = true
        } catch {
            submitError = NetworkMonitor.isNetworkError(error)
                ? "Không có kết nối mạng — vui lòng thử lại"
                : "Gửi báo cáo thất bại — thử lại sau"
        }
    }

    private static func appVersionString() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

#Preview {
    BugReportView(isPresented: .constant(true))
        .environmentObject(EventLogStore.shared)
}
