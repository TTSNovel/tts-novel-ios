import Foundation

/// What to do with a book's position pulled from the server — kept as a
/// pure function so every branch is unit-tested (ProgressReconcilerTests)
/// instead of living inside ProgressStore's async/persistence code.
///
/// The server only ever applies a write whose `base_rev` matched its
/// current rev, i.e. one made by a device that already knew the latest
/// position. So a newer remote position is trusted whichever direction it
/// moves — going back to re-read an old chapter is legitimate — and the
/// only questions are whether this device should *show* it now.
public enum ProgressReconciler {
    public enum Decision: Equatable, Sendable {
        /// Not newer than what this device already knows — nothing to do.
        case ignore
        /// Newer, but leave the displayed chapter alone: it's this device's
        /// own write, the chapter is the same anyway, or queued events of
        /// this book will be sent next (their outcome decides). Only the
        /// known server position (and so the next write's base) advances.
        case acknowledge
        /// Idle on this book: show the remote chapter (forward or back).
        case follow
        /// This device is listening to the book right now: don't touch the
        /// displayed chapter *or* the known rev — just tell the user. A
        /// later auto-next from here is then based on the old rev and gets
        /// a 409 (and a question) instead of silently overwriting the other
        /// device's choice; two listening sessions never quietly fight.
        case notify
    }

    /// - Parameters:
    ///   - knownRev: the server rev this device last accepted for the book
    ///     (0 if it never saw one).
    ///   - displayedChapter: the chapter this device shows for the book.
    public static func decide(
        knownRev: Int, displayedChapter: Int?, remote: ReadingProgress,
        hasPendingEvents: Bool, isPlaying: Bool, selfDeviceID: String
    ) -> Decision {
        guard remote.rev > knownRev else { return .ignore }
        if remote.deviceID == selfDeviceID || hasPendingEvents { return .acknowledge }
        if remote.chapterIndex == displayedChapter { return .acknowledge }
        return isPlaying ? .notify : .follow
    }
}
