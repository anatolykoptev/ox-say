import DictationCore
import SwiftUI

/// Словарь: the heard -> meant pairs that fix words the recogniser keeps getting wrong. The owner sees every pair,
/// approves or rejects the ones an assistant filed, changes what one means, deletes one for good, and adds their own.
/// All state and every daemon call live in `GlossaryModel` (DictationCore); this view draws it with system controls
/// only. Without the owner key the list still shows and the owner buttons are off, with a line saying why.
struct GlossaryPage: View {
    @StateObject private var model = GlossaryModel(client: .current())
    @State private var selection: GlossaryPair.ID?
    @State private var sheet: GlossarySheet?
    @State private var deleting: GlossaryPair?

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) { banners }
            .toolbar { toolbar }
            .task { await model.reload() }
            .sheet(item: $sheet) { which in
                GlossaryFormSheet(sheet: which, problem: model.problem) { heard, meant in
                    switch which {
                    case .add: return await model.add(heard: heard, meant: meant)
                    case .edit(let pair):
                        await model.edit(pair.id, meant: meant)
                        return model.problem == nil
                    }
                }
            }
            .confirmationDialog(deleting.map { L10nKey.glossaryDeleteTitle.text($0.heard) } ?? "",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { pair in
                Button(L10nKey.glossaryDeleteConfirm.text, role: .destructive) { Task { await model.delete(pair.id) } }
                Button(L10nKey.commonCancel.text, role: .cancel) {}
            } message: { _ in
                Text(L10nKey.glossaryDeleteBody.text)
            }
    }

    private var ownerOn: Bool { model.ownerAvailable && !model.busy }
    private var selected: GlossaryPair? { model.pairs.first { $0.id == selection } }

    // MARK: states

    @ViewBuilder private var content: some View {
        switch (model.load, model.pairs.isEmpty) {
        case (.loading, true):
            VStack(spacing: 12) {
                ProgressView()
                Text(L10nKey.glossaryLoading.text).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case (.failed(let sentence), true):
            ContentUnavailableView {
                Label(L10nKey.meetingsDownTitle.text, systemImage: "bolt.horizontal.circle")
            } description: {
                Text(sentence)
            } actions: {
                Button(L10nKey.commonRetry.text) { Task { await model.reload() } }.controlSize(.large)
            }
        case (.loaded, true):
            ContentUnavailableView {
                Label(L10nKey.glossaryEmptyTitle.text, systemImage: "character.book.closed")
            } description: {
                Text(L10nKey.glossaryEmptyMessage.text)
            } actions: {
                Button(L10nKey.glossaryAdd.text) { sheet = .add }.controlSize(.large).disabled(!ownerOn)
            }
        default:
            table
        }
    }

    private var table: some View {
        Table(model.visible, selection: $selection) {
            TableColumn(L10nKey.glossaryColHeard.text, value: \.heard)
            TableColumn(L10nKey.glossaryColMeant.text, value: \.meant)
            TableColumn(L10nKey.glossaryColStatus.text) { pair in
                Text(pair.status.titleKey.text).foregroundStyle(pair.status.tint)
            }
            .width(min: 90, ideal: 110)
            TableColumn(L10nKey.glossaryColSeen.text) { pair in
                Text("\(pair.seen)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 40, ideal: 50)
        }
        .contextMenu(forSelectionType: GlossaryPair.ID.self) { ids in
            if let id = ids.first, let pair = model.pairs.first(where: { $0.id == id }) { actions(for: pair) }
        } primaryAction: { ids in
            if ownerOn, let id = ids.first, let pair = model.pairs.first(where: { $0.id == id }) { sheet = .edit(pair) }
        }
        .overlay {
            if model.visible.isEmpty {
                Text(L10nKey.glossaryEmptyFilter.text).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func actions(for pair: GlossaryPair) -> some View {
        Button(L10nKey.glossaryApprove.text) { Task { await model.approve(pair.id) } }
            .disabled(!ownerOn || pair.status == .active)
        Button(L10nKey.glossaryReject.text) { Task { await model.reject(pair.id) } }
            .disabled(!ownerOn || pair.status == .rejected)
        Button(L10nKey.glossaryEdit.text) { sheet = .edit(pair) }.disabled(!ownerOn)
        Divider()
        Button(L10nKey.glossaryDelete.text, role: .destructive) { deleting = pair }.disabled(!ownerOn)
    }

    // MARK: banners and toolbar

    @ViewBuilder private var banners: some View {
        VStack(spacing: 0) {
            if !model.ownerAvailable {
                NoticeBar(text: L10nKey.glossaryOwnerMissing.text, symbol: "lock.fill", tint: .orange,
                          actionTitle: L10nKey.commonRetry.text) { Task { await model.reload() } }
            }
            if let problem = model.problem {
                NoticeBar(text: problem, symbol: "exclamationmark.triangle.fill", tint: .orange) { model.dismissProblem() }
            }
            if case .failed(let sentence) = model.load, !model.pairs.isEmpty {
                NoticeBar(text: sentence, symbol: "exclamationmark.triangle.fill", tint: .orange,
                          actionTitle: L10nKey.commonRetry.text) { Task { await model.reload() } }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker(L10nKey.glossaryFilterLabel.text, selection: $model.filter) {
                ForEach(GlossaryFilter.allCases, id: \.self) { f in
                    Text("\(f.titleKey.text) (\(model.count(f)))").tag(f)
                }
            }
            .pickerStyle(.menu)
        }
        ToolbarItemGroup {
            Button { if let p = selected { Task { await model.approve(p.id) } } } label: {
                Label(L10nKey.glossaryApprove.text, systemImage: "checkmark.circle")
            }
            .disabled(!ownerOn || selected == nil || selected?.status == .active)
            Button { if let p = selected { Task { await model.reject(p.id) } } } label: {
                Label(L10nKey.glossaryReject.text, systemImage: "xmark.circle")
            }
            .disabled(!ownerOn || selected == nil || selected?.status == .rejected)
            Button { if let p = selected { sheet = .edit(p) } } label: {
                Label(L10nKey.glossaryEdit.text, systemImage: "pencil")
            }
            .disabled(!ownerOn || selected == nil)
            Button { deleting = selected } label: {
                Label(L10nKey.glossaryDelete.text, systemImage: "trash")
            }
            .disabled(!ownerOn || selected == nil)
            Button { sheet = .add } label: {
                Label(L10nKey.glossaryAdd.text, systemImage: "plus")
            }
            .disabled(!ownerOn)
        }
    }
}

extension GlossaryStatus {
    var titleKey: L10nKey {
        switch self {
        case .candidate: return .glossaryStatusCandidate
        case .active: return .glossaryStatusActive
        case .rejected: return .glossaryStatusRejected
        case .unknown: return .glossaryStatusUnknown
        }
    }

    var tint: Color {
        switch self {
        case .candidate: return .orange
        case .active: return .green
        case .rejected, .unknown: return .secondary
        }
    }
}

/// What the page's one sheet is for.
enum GlossarySheet: Identifiable {
    case add
    case edit(GlossaryPair)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let pair): return "edit-\(pair.id)"
        }
    }
}

/// The add / edit form: two fields for a new pair, the meant field alone for an edit (the heard form is the pair's
/// identity). `submit` returns whether it went through; the sheet closes only then, so a refusal keeps what was typed.
struct GlossaryFormSheet: View {
    let sheet: GlossarySheet
    /// The daemon's refusal of the last try, shown under the fields: the page's own bar is behind the sheet.
    let problem: String?
    let submit: (_ heard: String, _ meant: String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var heard = ""
    @State private var meant = ""
    @State private var sending = false

    init(sheet: GlossarySheet, problem: String?, submit: @escaping (_ heard: String, _ meant: String) async -> Bool) {
        self.sheet = sheet
        self.problem = problem
        self.submit = submit
        if case .edit(let pair) = sheet {
            _heard = State(initialValue: pair.heard)
            _meant = State(initialValue: pair.meant)
        }
    }

    private var isEdit: Bool { if case .edit = sheet { return true } else { return false } }
    private var ready: Bool {
        !meant.trimmingCharacters(in: .whitespaces).isEmpty && !heard.trimmingCharacters(in: .whitespaces).isEmpty && !sending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEdit ? L10nKey.glossaryEditTitle.text(heard) : L10nKey.glossaryAddTitle.text).font(.headline)
            if !isEdit {
                TextField(L10nKey.glossaryAddHeard.text, text: $heard).textFieldStyle(.roundedBorder)
            }
            TextField(isEdit ? L10nKey.glossaryEditField.text : L10nKey.glossaryAddMeant.text, text: $meant)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
            if let problem { Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(L10nKey.commonCancel.text, role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10nKey.commonSave.text, action: send).keyboardShortcut(.defaultAction).disabled(!ready)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func send() {
        guard ready else { return }
        sending = true
        Task {
            let ok = await submit(heard, meant)
            sending = false
            if ok { dismiss() }
        }
    }
}
