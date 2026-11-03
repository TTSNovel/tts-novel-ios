import SwiftUI
import Core

/// Reading-history messages for the book open in the reader (see
/// ProgressStore): a conflict — this device's chapter change was rejected
/// because another device moved the book first — or a remote notice —
/// another device moved the book while this one is listening. Neither
/// interrupts audio; the user decides here, on the device they're holding.
/// Overlaid at the top of ReaderView rather than inset, so it appearing or
/// going away never re-lays-out the chapter pager underneath.
struct ReadingSyncBanner: View {
    let book: Book
    let onShowHistory: () -> Void

    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var playback: ReaderPlaybackController

    var body: some View {
        if let conflict = progressStore.conflicts[book.id] {
            conflictBanner(conflict)
        } else if let notice = progressStore.remoteNotices[book.id] {
            noticeBanner(notice)
        }
    }

    private func conflictBanner(_ conflict: ProgressConflict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(Self.deviceLabel(conflict.server)) đang ở chương \(conflict.server.chapterIndex + 1) (\(Self.time.string(from: conflict.server.updatedAt))).")
                .font(.subheadline)
                .accessibilityIdentifier("readingConflictMessage")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { conflictButtons(conflict) }
                VStack(alignment: .leading, spacing: 6) { conflictButtons(conflict) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .modifier(BannerChrome())
    }

    @ViewBuilder
    private func conflictButtons(_ conflict: ProgressConflict) -> some View {
        Button("Đọc chương \(conflict.attemptedChapter + 1) ở đây") {
            progressStore.keepLocal(bookID: book.id)
        }
        .accessibilityIdentifier("readingConflictKeepLocalButton")
        Button("Chuyển tới chương \(conflict.server.chapterIndex + 1)") {
            playback.moveToServerChapter(bookID: book.id)
        }
        .accessibilityIdentifier("readingConflictAdoptServerButton")
        Button("Lịch sử", action: onShowHistory)
            .accessibilityIdentifier("readingConflictHistoryButton")
    }

    private func noticeBanner(_ notice: RemoteProgressNotice) -> some View {
        HStack(spacing: 8) {
            Text("\(Self.deviceLabel(notice.server)) đã chuyển sang chương \(notice.server.chapterIndex + 1)")
                .font(.subheadline)
                .accessibilityIdentifier("remoteProgressNoticeMessage")
            Spacer(minLength: 4)
            Button("Chuyển") {
                playback.moveToServerChapter(bookID: book.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("remoteProgressNoticeMoveButton")
            Button {
                progressStore.dismissNotice(bookID: book.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Bỏ qua")
            .accessibilityIdentifier("remoteProgressNoticeDismissButton")
        }
        .modifier(BannerChrome())
    }

    /// "18:19" in local time, whatever the system's 12/24-hour setting.
    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func deviceLabel(_ position: ReadingProgress) -> String {
        guard let name = position.deviceName, !name.isEmpty else { return "Thiết bị khác" }
        return name
    }
}

private struct BannerChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .padding(.horizontal)
            .padding(.top, 8)
    }
}
