import DictationCore
import SwiftUI

/// «Описать словами»: the form, then the variants one by one. A window-modal sheet on the Voices page. It holds the
/// text being typed and nothing else: which step comes next is the flow's (VoiceDesignFlow), and every button is one
/// `VoiceDesignAction`. Esc cancels, Return keeps (or submits the form).
public struct VoiceDesignSheet: View {
    let flow: VoiceDesignFlow
    let send: (VoiceDesignAction) -> Void
    @State private var description: String
    @State private var sentence: String
    @State private var label: String

    public init(flow: VoiceDesignFlow, send: @escaping (VoiceDesignAction) -> Void) {
        self.flow = flow
        self.send = send
        _description = State(initialValue: flow.description)
        _sentence = State(initialValue: flow.sentence)
        _label = State(initialValue: flow.label)
    }

    public var body: some View {
        Group {
            switch flow.phase {
            case .form: form
            case .designing: working(L10nKey.designDesigningPill.text, cancel: true)
            case .reviewing(let index): review(index: index)
            case .done: working(L10nKey.designSaving.text, cancel: false)
            case .saving: flow.confirmReplace.map { replaceQuestion(flow.label.isEmpty ? $0 : flow.label) } ?? AnyView(working(L10nKey.designSaving.text, cancel: false))
            case .failed(let sentence): failure(sentence)
            }
        }
        .padding(20)
        .frame(width: 440)
        // Esc is the cancel button's shortcut on every step; a step with no cancel button still answers it.
        .background(Button("") { send(.escape) }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true))
    }

    // MARK: form

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10nKey.designFormTitle.text).font(.headline)
            Text(L10nKey.designFormInfo.text).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            field(L10nKey.designFormDescriptionLabel.text) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $description)
                        .font(.body)
                        .frame(height: 76)
                        .accessibilityLabel(L10nKey.designFormDescriptionLabel.text)
                    if description.isEmpty {
                        Text(DesignForm.descriptionPlaceholder())
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5).padding(.vertical, 8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
            }
            field(L10nKey.designFormSentenceLabel.text) {
                TextField("", text: $sentence, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
                    .accessibilityLabel(L10nKey.designFormSentenceLabel.text)
            }
            field(L10nKey.designFormNameLabel.text) {
                TextField(L10nKey.designFormNamePlaceholder.text, text: $label)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10nKey.designFormNameLabel.text)
            }
            if let problem = flow.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L10nKey.commonCancel.text) { send(.escape) }
                Button(L10nKey.designFormCreate.text) {
                    send(.submit(description: description, sentence: sentence, label: label))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: waiting

    private func working(_ text: String, cancel: Bool) -> some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
            if cancel {
                Button(L10nKey.commonCancel.text) { send(.escape) }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .accessibilityElement(children: .combine)
    }

    // MARK: variants

    private func review(index: Int) -> some View {
        let take = flow.takes.indices.contains(index) ? flow.takes[index] : nil
        let keptAs = flow.label.isEmpty ? (take?.suggestedName ?? "") : flow.label
        return VStack(spacing: 14) {
            Text(DesignForm.takeTitle(index: index, count: flow.takes.count)).font(.headline)
            Button { send(.replay) } label: {
                Image(systemName: "play.fill").font(.system(size: 28)).frame(width: 72, height: 72)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10nKey.designTakeReplay.text)
            .help(L10nKey.designTakeReplay.text)
            if let warning = take?.warning {
                Label(DesignForm.warningText(warning), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !keptAs.isEmpty {
                Text(L10nKey.designTakeSavedAs.text(keptAs)).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button(L10nKey.commonCancel.text) { send(.escape) }
                Spacer()
                Button(L10nKey.designTakeNext.text) { send(.next) }
                Button(L10nKey.designTakeKeep.text) { send(.keep) }.keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func replaceQuestion(_ id: String) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 12) {
            Text(L10nKey.designExistsTitle.text(id)).font(.headline)
            Text(L10nKey.designExistsText.text).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10nKey.commonCancel.text) { send(.replace(false)) }
                Button(L10nKey.designExistsButton.text) { send(.replace(true)) }.keyboardShortcut(.defaultAction)
            }
        })
    }

    // MARK: failure

    private func failure(_ sentence: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 30)).foregroundStyle(.orange)
            Text(L10nKey.designFailedTitle.text).font(.headline)
            Text(sentence).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10nKey.commonOk.text) { send(.escape) }.keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
