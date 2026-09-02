import SwiftUI

extension ToolbarItemPlacement {
    /// `.topBarTrailing` on iOS/iPadOS *and* watchOS (both support it —
    /// confirmed by a real watchOS build+run; a `.automatic` item placed
    /// this way didn't actually render a visible/tappable toolbar button
    /// there, `.topBarTrailing` does). Only macOS hard-rejects it at
    /// compile time (no concept of a "top bar" — a navigation-stack
    /// toolbar there is just the window's own toolbar), where
    /// `.automatic` places the item using the window toolbar's own
    /// convention instead.
    static var readerTrailing: ToolbarItemPlacement {
        #if os(macOS)
        return .automatic
        #else
        return .topBarTrailing
        #endif
    }

    static var readerLeading: ToolbarItemPlacement {
        #if os(macOS)
        return .automatic
        #else
        return .topBarLeading
        #endif
    }
}

extension View {
    /// `.navigationBarTitleDisplayMode(.inline)` on iOS; a no-op on macOS,
    /// which has no equivalent concept — window titles there are already
    /// compact, nothing to opt into.
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// `.textInputAutocapitalization(.never)` on iOS (unavailable on
    /// macOS); a no-op on macOS, where text fields don't auto-capitalize
    /// to begin with.
    @ViewBuilder
    func neverAutocapitalized() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}
