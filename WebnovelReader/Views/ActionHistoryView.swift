import SwiftUI

/// Doubles as the "action history" screen (feature: xem lịch sử thao tác,
/// filter theo loại) and the debug log viewer (feature: xem log) — both read
/// the same EventLogStore timeline, since a bug is most legible alongside
/// the actions that led up to it. Reached from ReaderSettingsSheet ("Nhật ký
/// & lịch sử"), same place on every screen as everything else in that sheet.
struct ActionHistoryView: View {
    @EnvironmentObject private var eventLog: EventLogStore
    @State private var selectedCategories: Set<AppEventCategory> = []
    @State private var showingClearConfirm = false

    private var filtered: [AppEvent] {
        eventLog.entries(matching: selectedCategories)
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                ContentUnavailableView(
                    "Chưa có hoạt động nào", systemImage: "clock.arrow.circlepath",
                    description: Text("Thao tác trong ứng dụng sẽ được ghi lại ở đây.")
                )
                .listRowSeparator(.hidden)
            } else {
                ForEach(filtered) { event in
                    row(for: event)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Nhật ký & lịch sử")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        selectedCategories = []
                    } label: {
                        if selectedCategories.isEmpty {
                            Label("Tất cả", systemImage: "checkmark")
                        } else {
                            Text("Tất cả")
                        }
                    }
                    ForEach(AppEventCategory.allCases) { category in
                        Button {
                            toggle(category)
                        } label: {
                            if selectedCategories.contains(category) {
                                Label(category.displayName, systemImage: "checkmark")
                            } else {
                                Text(category.displayName)
                            }
                        }
                    }
                } label: {
                    Image(systemName: selectedCategories.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("historyFilterButton")
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: exportText()) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(filtered.isEmpty)
                .accessibilityIdentifier("historyShareButton")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showingClearConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(eventLog.events.isEmpty)
                .accessibilityIdentifier("historyClearButton")
            }
        }
        .confirmationDialog("Xoá toàn bộ nhật ký?", isPresented: $showingClearConfirm, titleVisibility: .visible) {
            Button("Xoá", role: .destructive) { eventLog.clear() }
            Button("Huỷ", role: .cancel) {}
        }
    }

    private func row(for event: AppEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.category.systemImage)
                .foregroundStyle(event.category == .error ? .red : .accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.message).font(.body)
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(event.timestamp, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func toggle(_ category: AppEventCategory) {
        if selectedCategories.contains(category) {
            selectedCategories.remove(category)
        } else {
            selectedCategories.insert(category)
        }
    }

    private func exportText() -> String {
        EventLogStore.exportText(filtered)
    }
}

extension EventLogStore {
    /// Plain-text rendering shared by ActionHistoryView's ShareLink export
    /// and BugReportView's attached-log payload.
    static func exportText(_ events: [AppEvent]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return events.map { event -> String in
            let time = formatter.string(from: event.timestamp)
            let detail = event.detail.map { " — \($0)" } ?? ""
            return "[\(time)] [\(event.category.displayName)] \(event.message)\(detail)"
        }.joined(separator: "\n")
    }
}

#Preview {
    NavigationStack {
        ActionHistoryView()
    }
    .environmentObject(EventLogStore.shared)
}
