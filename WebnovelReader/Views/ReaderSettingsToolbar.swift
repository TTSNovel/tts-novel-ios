import SwiftUI

// Applied to every screen (Library, BookDetail, History, Downloaded,
// Reader) so the settings gear reads as an app-wide, always-reachable
// action — top-right of the nav bar, same spot on every page — rather
// than something scoped to a single screen. Each screen owns its own
// `showingSettings` state (via this modifier) since a shared one on the
// bar itself isn't what's wanted here; the sheet content is identical
// everywhere via the shared ReaderSettingsSheet.
private struct ReaderSettingsToolbarModifier: ViewModifier {
    @State private var showingSettings = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Cài đặt đọc")
                    .accessibilityIdentifier("voiceMenuButton")
                }
            }
            .sheet(isPresented: $showingSettings) {
                ReaderSettingsSheet(isPresented: $showingSettings)
            }
    }
}

extension View {
    func readerSettingsToolbar() -> some View {
        modifier(ReaderSettingsToolbarModifier())
    }
}
