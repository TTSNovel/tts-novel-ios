import SwiftUI
import Core

/// Reached from ReaderSettingsSheet ("Glossary", shown for the Google and
/// Apple engines — Apple's applies it on device, see `Glossary`) — edits the server's translation glossary: terms shared by every
/// book, and terms of just the open book (see `GlossaryTerm`). Every
/// add/edit/delete saves the whole list right away; the server publishes it
/// to Google before answering, then the open chapter is re-translated.
///
/// Same plain ScrollView + custom header layout as FilterWordsView, for the
/// same macOS reasons documented there (List insets, `.toolbar` items
/// rendering into an overlapping bottom bar inside the settings sheet).
struct GlossaryView: View {
    let bookID: Int
    @EnvironmentObject private var playback: ReaderPlaybackController

    private enum Scope: String, CaseIterable, Identifiable {
        case book = "This book"
        case shared = "All books"
        var id: String { rawValue }
    }

    @State private var scope: Scope = .book
    @State private var terms: [GlossaryTerm] = []
    @State private var isLoaded = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var editing: GlossaryTerm?

    private var scopeBookID: Int? { scope == .book ? bookID : nil }
    private var visibleTerms: [GlossaryTerm] { terms.filter { $0.bookID == scopeBookID } }

    var body: some View {
        GeometryReader { outerGeo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Picker("Scope", selection: $scope) {
                        ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .accessibilityIdentifier("glossaryScopePicker")
                    headerRow
                    if !isLoaded {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else if visibleTerms.isEmpty {
                        Text("No terms yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else {
                        ForEach(Array(visibleTerms.enumerated()), id: \.element.id) { index, term in
                            row(for: term, showsDivider: index < visibleTerms.count - 1)
                        }
                    }
                    footerRow
                }
                .frame(width: outerGeo.size.width, alignment: .leading)
            }
        }
        #if os(macOS)
        // Room for the settings sheet's floating "Done" button — see
        // FilterWordsView.
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 44) }
        #endif
        .navigationTitle("Glossary")
        .inlineNavigationTitle()
        .task { await load() }
        .sheet(item: $editing) { term in
            GlossaryTermEditor(
                term: term,
                isNew: !terms.contains { $0.id == term.id },
                onSave: { edited in
                    if let index = terms.firstIndex(where: { $0.id == edited.id }) {
                        terms[index] = edited
                    } else {
                        terms.insert(edited, at: 0)
                    }
                    editing = nil
                    Task { await save() }
                },
                onDelete: {
                    terms.removeAll { $0.id == term.id }
                    editing = nil
                    Task { await save() }
                },
                onCancel: { editing = nil }
            )
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(scope == .book ? "Only this book" : "Every book")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            if isSaving {
                ProgressView().controlSize(.small)
                Text("Saving…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("+ Add") {
                editing = GlossaryTerm(source: "", target: "", bookID: scopeBookID)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .disabled(!isLoaded || isSaving)
            .accessibilityIdentifier("glossaryAddButton")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var footerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("glossaryError")
            }
            Text("Used by Google Translate. A book's own terms win over shared ones. Leave the translation blank to keep a term as is.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private func row(for term: GlossaryTerm, showsDivider: Bool) -> some View {
        Button {
            editing = term
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(term.source)
                        .font(.system(size: 13.5))
                        .lineLimit(2)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(term.keepsOriginal ? "keep as is" : term.target)
                        .font(.system(size: 13.5))
                        .foregroundStyle(term.keepsOriginal ? .secondary : .primary)
                        .italic(term.keepsOriginal)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                if showsDivider { Divider() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityIdentifier("glossaryRow")
        .contextMenu {
            Button(role: .destructive) {
                terms.removeAll { $0.id == term.id }
                Task { await save() }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func load() async {
        do {
            terms = try await APIClient.shared.fetchGlossary(baseURL: SessionStore.baseURL)
            isLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load the glossary (\(error.localizedDescription))."
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            terms = try await APIClient.shared.saveGlossary(baseURL: SessionStore.baseURL, terms: terms)
            errorMessage = nil
            playback.glossaryDidChange(terms)
        } catch {
            errorMessage = "Couldn't save the glossary (\(error.localizedDescription)). Your edit may not apply yet."
        }
    }
}

/// Add/edit sheet for one term — same flat header style as
/// FilterWordEditorView.
private struct GlossaryTermEditor: View {
    let term: GlossaryTerm
    let isNew: Bool
    let onSave: (GlossaryTerm) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var source: String
    @State private var target: String

    init(term: GlossaryTerm, isNew: Bool, onSave: @escaping (GlossaryTerm) -> Void, onDelete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.term = term
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _source = State(initialValue: term.source)
        _target = State(initialValue: term.keepsOriginal ? "" : term.target)
    }

    private var trimmedSource: String { source.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var fieldBackground: some ShapeStyle {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(.secondarySystemBackground)
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text(isNew ? "Add Term" : "Edit Term")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Save") {
                    var edited = term
                    edited.source = trimmedSource
                    let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
                    edited.target = trimmedTarget.isEmpty ? trimmedSource : trimmedTarget
                    onSave(edited)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(trimmedSource.isEmpty ? Color.secondary : Color.accentColor)
                .disabled(trimmedSource.isEmpty)
                .accessibilityIdentifier("glossarySaveButton")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                field("Term (e.g. Dao)", text: $source, id: "glossarySourceField")
                field("Translation — blank keeps it as is", text: $target, id: "glossaryTargetField")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 14)
            if !isNew {
                Divider()
                Button(role: .destructive) { onDelete() } label: {
                    Label("Delete this term", systemImage: "trash")
                        .font(.system(size: 13.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .padding(12)
                .accessibilityIdentifier("glossaryDeleteButton")
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 440, minHeight: 200)
        #endif
    }

    private func field(_ title: String, text: Binding<String>, id: String) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(fieldBackground))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.3)))
            .accessibilityIdentifier(id)
    }
}
