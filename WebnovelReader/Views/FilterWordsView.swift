import SwiftUI
import Core

/// Reached from ReaderSettingsSheet ("Filter Words") — lets the user manage
/// the list of patterns `TextSegmentation.cleaned(_:filterRules:)` strips
/// from chapter text before it reaches TTS synthesis. Backed by
/// `FilterWordsStore.shared`, which persists locally and syncs to the server.
///
/// Layout mirrors the design mockup's literal CSS box model (padding/gap/
/// font-size values taken straight from its `.section-label`/`.row`/
/// `.section-footer` rules) rather than relying on `List`/`Form`'s own
/// default insets. This is a plain `ScrollView` + `VStack`, not a `List` —
/// `List` was tried first with every row's `.listRowInsets` zeroed out, but
/// on macOS `List`/`NSTableView` also apply their own outer content inset
/// that `.listRowInsets` doesn't reach. Trade-off: `.swipeActions` only
/// exists on `List`, so this drops native iOS swipe-to-delete —
/// `.contextMenu` (right-click on macOS, long-press on iOS) plus the
/// editor's own Delete row are the delete paths instead.
///
/// This view is pushed inside ReaderSettingsSheet's macOS NavigationStack,
/// which once (when ReaderSettingsSheet's root was a `Form`) placed pushed
/// content ~18pt in from the window's leading edge without shrinking the
/// width proposal to match, clipping "+ Add" and the row pencil icon at the
/// trailing edge. That was fixed at the time with a hardcoded `.offset(x:
/// -18.25)` on the ScrollView. When ReaderSettingsSheet's root was later
/// rewritten away from `Form` (see its own doc comment), the offset was
/// carried over unexamined — and became actively wrong: the NavigationStack
/// no longer had that overflow, so the leftover offset shifted correctly-
/// placed content off the *leading* edge instead. Re-measuring with a
/// temporary GeometryReader + NSWindow probe (not screenshots — see
/// [[feedback_swiftui_macos_layout_debugging]]) showed this view's content
/// frame exactly matching the window's bounds with no offset needed, so the
/// hack was removed rather than re-tuned. If a similar overflow reappears
/// after some other change to ReaderSettingsSheet's presentation, re-measure
/// from scratch rather than reintroducing a fixed constant — this exact
/// number was never a stable property of "NavigationStack on macOS" in
/// general, only of one specific former layout of its parent.
///
/// Deliberately does NOT use `.toolbar` for "+ Add"/"Cancel"/"Save": on
/// macOS, any `.toolbar` item on a view pushed/presented inside this app's
/// settings `NavigationStack` + `.sheet` renders into a bottom action bar
/// that overlaps list content instead of reserving space for itself (real
/// AppKit window chrome, not a SwiftUI overlay — confirmed across several
/// failed workarounds: `.safeAreaInset` on child and parent, a fixed-height
/// spacer, enlarging `idealHeight`). Plain buttons in a custom header row
/// sidestep the whole problem.
struct FilterWordsView: View {
    @ObservedObject private var store = FilterWordsStore.shared
    @State private var editorContext: FilterWordEditorContext?

    var body: some View {
        GeometryReader { outerGeo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerRow
                    if store.rules.isEmpty {
                        emptyRow
                    } else {
                        ForEach(Array(store.rules.enumerated()), id: \.element.id) { index, rule in
                            row(for: rule, showsDivider: index < store.rules.count - 1)
                        }
                    }
                    footerRow
                }
                .frame(width: outerGeo.size.width, alignment: .leading)
            }
        }
        #if os(macOS)
        // ReaderSettingsSheet's own "Done" toolbar button is real AppKit
        // window chrome on macOS — it floats fixed at the window's
        // bottom-right corner instead of reserving space in SwiftUI's
        // layout (see this view's doc comment), so it sits on top of
        // whatever the last row of any pushed list happens to be. This
        // doesn't make the button itself move (that part's unfixable, see
        // the doc comment) — it just gives the scroll content extra room
        // so the last row can scroll clear of it.
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 44)
        }
        #endif
        .navigationTitle("Filter Words")
        .inlineNavigationTitle()
        .sheet(item: $editorContext) { context in
            FilterWordEditorView(
                context: context,
                onSave: { rule in
                    switch context {
                    case .add: store.add(pattern: rule.pattern, isRegex: rule.isRegex)
                    case .edit: store.update(rule)
                    }
                    editorContext = nil
                },
                onDelete: {
                    if case .edit(let rule) = context { store.delete(id: rule.id) }
                    editorContext = nil
                },
                onCancel: { editorContext = nil }
            )
        }
    }

    // .section-label { padding: 14px 14px 6px; font-size: 12px; }
    private var headerRow: some View {
        HStack {
            // Default macOS/iOS Section header styling renders this as
            // sentence-case with no tracking — the mockup calls for a small
            // tracked all-caps label, set explicitly since this is a plain
            // row now, not a Section header.
            Text("List")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer()
            Button("+ Add") { editorContext = .add }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("filterWordsAddButton")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    // .empty { padding: 40px 20px; font-size: 13px; }
    private var emptyRow: some View {
        Text("No filter words yet.")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .padding(.horizontal, 20)
    }

    // .section-footer { padding: 8px 14px 14px; font-size: 12px; line-height: 1.4; }
    private var footerRow: some View {
        // No native swipeActions outside List (see this view's doc comment)
        // — wording reflects the actual delete paths instead of promising a
        // gesture that no longer exists.
        Text("Tap an item to edit. Long-press or right-click to delete. Raw pattern is not shown here — only in the edit screen.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 14)
    }

    // .row { padding: 12px 14px; gap: 10px; border-bottom: 1px solid divider; }
    // .row:last-child { border-bottom: none; } — box-sizing:border-box in the
    // mockup means that border spans the row's full width, not inset to the
    // text — so the Divider below deliberately gets no extra leading padding.
    private func row(for rule: FilterWordRule, showsDivider: Bool) -> some View {
        Button {
            editorContext = .edit(rule)
        } label: {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.label ?? rule.pattern)
                            .font(.system(size: 13.5))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(rule.isRegex ? "REGEX" : "PLAIN TEXT")
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(0.2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(rule.isRegex ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.15))
                            .foregroundStyle(rule.isRegex ? Color.accentColor : .secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                if showsDivider {
                    Divider()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("filterWordRow")
        .contextMenu {
            Button(role: .destructive) {
                store.delete(id: rule.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

/// Identifies which mode the shared editor sheet is in — `.add` starts blank,
/// `.edit` prefills from an existing rule and shows the delete row.
private enum FilterWordEditorContext: Identifiable {
    case add
    case edit(FilterWordRule)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let rule): return rule.id.uuidString
        }
    }

    var existingRule: FilterWordRule? {
        if case .edit(let rule) = self { return rule }
        return nil
    }
}

/// Shared by both Add and Edit — the only difference is whether `context`
/// carries an existing rule to prefill from (and whether the delete row
/// shows). See `FilterWordsView`'s doc comment for why this has its own
/// plain-button header instead of `.toolbar`, and for the box-model-matches-
/// the-mockup rationale behind the explicit paddings below.
private struct FilterWordEditorView: View {
    let context: FilterWordEditorContext
    let onSave: (FilterWordRule) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var pattern: String
    @State private var isRegex: Bool
    @State private var showingDeleteConfirm = false

    init(context: FilterWordEditorContext, onSave: @escaping (FilterWordRule) -> Void, onDelete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.context = context
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _pattern = State(initialValue: context.existingRule?.pattern ?? "")
        _isRegex = State(initialValue: context.existingRule?.isRegex ?? true)
    }

    private var trimmedPattern: String {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isPatternValid: Bool {
        guard !trimmedPattern.isEmpty else { return false }
        guard isRegex else { return true }
        return (try? NSRegularExpression(pattern: trimmedPattern)) != nil
    }

    // Matches the mockup's .text-input box: a single styled field with no
    // separate outside label (a bare TextField inside a Form renders its
    // title as a persistent leading label on macOS — that's the "Pattern"
    // label the design doesn't have; dropping Form and styling the field
    // directly avoids it, and the title still shows as a placeholder).
    private var patternFieldBackground: some ShapeStyle {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(.secondarySystemBackground)
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // .field-group { padding: 6px 14px 14px; gap: 10px; }
            VStack(alignment: .leading, spacing: 10) {
                // .text-input { padding: 8px 10px; border-radius: 7px; font-size: 13.5px; }
                TextField("Pattern", text: $pattern, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1...4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(patternFieldBackground))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.3)))
                    .accessibilityIdentifier("filterWordPatternField")
                // .toggle-row { font-size: 13.5px; }
                HStack {
                    Text("Regex")
                        .font(.system(size: 13.5))
                    Spacer()
                    Toggle("Regex", isOn: $isRegex)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("filterWordRegexToggle")
                }
                if isRegex, !trimmedPattern.isEmpty, !isPatternValid {
                    Text("Invalid regular expression")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 14)
            if context.existingRule != nil {
                Divider()
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete this filter word", systemImage: "trash")
                        .font(.system(size: 13.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                // .plain strips macOS's default bezeled-button fill — the
                // mockup's delete row is flat red text, not a gray button.
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                // .delete-row { padding: 12px; }
                .padding(12)
                .accessibilityIdentifier("filterWordDeleteButton")
            }
        }
        .confirmationDialog("Delete this filter word?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        }
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 440, minHeight: 260)
        #endif
    }

    // .titlebar { padding: 10px 14px; font-size: 13px; }
    // .titlebar .title { font-weight: 600; font-size: 13px; }
    private var header: some View {
        HStack {
            // .plain strips macOS's default bezeled-button chip — the
            // mockup's Cancel/Save are flat accent-colored text, not
            // buttons with a gray background.
            Button("Cancel") { onCancel() }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("filterWordCancelButton")
            Spacer()
            Text(context.existingRule != nil ? "Edit Filter Word" : "Add Filter Word")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button("Save") { save() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isPatternValid ? Color.accentColor : Color.secondary)
                .disabled(!isPatternValid)
                .accessibilityIdentifier("filterWordSaveButton")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func save() {
        // Cleared once the pattern/isRegex actually change — see
        // FilterWordRule's doc comment: a label describes the *original*
        // pattern, so it stops being accurate the moment that changes.
        let original = context.existingRule
        let unchanged = original?.pattern == trimmedPattern && original?.isRegex == isRegex
        let rule = FilterWordRule(
            id: original?.id ?? UUID(),
            pattern: trimmedPattern,
            isRegex: isRegex,
            label: unchanged ? original?.label : nil
        )
        onSave(rule)
    }
}

#Preview {
    NavigationStack {
        FilterWordsView()
    }
}
