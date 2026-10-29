import DictationCore
import SwiftUI

/// Settings: meetings, permissions, general. One grouped Form; every row says what it does in
/// plain words, and a permission row says whether it works and opens the right System Settings page.
struct SettingsPage: View {
    @ObservedObject var model: MainWindowModel

    private var s: Binding<MeetingSettingsValues> { model.meetingSettings }

    var body: some View {
        Form {
            meetings
            if model.data.meetingSettings.enabled { callApps }
            permissions
            general
        }
        .formStyle(.grouped)
        .navigationTitle(L10nKey.sectionSettings.text)
    }

    // MARK: Meetings

    private var meetings: some View {
        Section {
            ToggleRow(title: L10nKey.settingsMeetingsToggle.text, hint: L10nKey.settingsMeetingsToggleFooter.text,
                      isOn: s.enabled)
            if s.wrappedValue.enabled {
                HintedRow(title: L10nKey.settingsWhenCall.text, hint: L10nKey.settingsAutoFooter.text) {
                    Picker("", selection: s.callMode) {
                        ForEach(CallGlobalMode.allCases, id: \.self) { Text($0.titleKey.text).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                HintedRow(title: L10nKey.settingsFolder.text, hint: (s.wrappedValue.folderPath as NSString).abbreviatingWithTildeInPath) {
                    Button(L10nKey.commonChoose.text) { model.actions.chooseNotesFolder() }
                    Button(L10nKey.commonOpen.text) { model.actions.openNotesFolder() }
                }
                HintedRow(title: L10nKey.settingsKeep.text,
                          hint: s.wrappedValue.retentionVerified ? L10nKey.settingsKeepFooter.text : L10nKey.settingsKeepUnchecked.text) {
                    Picker("", selection: s.retention) {
                        ForEach(MeetingRetention.allCases, id: \.self) { Text($0.titleKey.text).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                HintedRow(title: L10nKey.settingsName.text) {
                    NameField(saved: s.wrappedValue.yourName, fallback: s.wrappedValue.yourNameFallback) { s.yourName.wrappedValue = $0 }
                }
                notesWriter
            }
        } header: {
            Text(L10nKey.sectionMeetings.text)
        }
    }

    private var notesWriter: some View {
        HintedRow(title: L10nKey.settingsNotesWriter.text, hint: L10nKey.settingsNotesWriterFooter.text) {
            switch s.wrappedValue.notesWriter {
            case .ready:
                Label(L10nKey.settingsNotesWriterReady.text, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).labelStyle(.titleAndIcon)
            case .engineFailed(let why):
                VStack(alignment: .trailing, spacing: 4) {
                    Label(L10nKey.settingsNotesWriterReady.text, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).labelStyle(.titleAndIcon)
                    Text(why.text).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.trailing)
                }
            case .missing:
                Text(L10nKey.settingsNotesWriterMissing.text).font(.callout).foregroundStyle(.secondary)
                Button(L10nKey.settingsNotesWriterDownload.text) { model.actions.downloadNotesWriter() }
            case .downloadFailed(let why):
                VStack(alignment: .trailing, spacing: 4) {
                    Text(why.text).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.trailing)
                    Button(L10nKey.settingsNotesWriterDownload.text) { model.actions.downloadNotesWriter() }
                }
            case .downloading(let percent):
                ProgressView(value: Double(percent), total: 100).frame(width: 110)
                Text("\(percent)%").monospacedDigit().foregroundStyle(.secondary)
            case .unavailable(let why):
                Text(why.text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Which apps

    private var callApps: some View {
        let global = s.wrappedValue.callMode
        let apps = model.data.meetingSettings.apps
        let effective = { (app: CallApp) in CallPolicy.effectiveMode(for: app.id, global: global, picked: app.mode) }
        let auto = apps.filter { effective($0) == .auto }.count
        let ask = apps.filter { effective($0) == .ask }.count
        // Under Off every app is off; the summary says so instead of two zero counts.
        let summary = global == .off ? L10nKey.settingsCallOff.text : String(format: L10nKey.settingsAppsSummary.text, auto, ask)
        return Section {
            DisclosureGroup(isExpanded: $model.appsExpanded) {
                ForEach(s.apps) { $app in
                    HintedRow(title: app.name, hint: app.noteKey?.text) {
                        Picker("", selection: $app.mode) {
                            Text(String(format: L10nKey.settingsAppsDefault.text,
                                        CallPolicy.effectiveMode(for: app.id, global: global, picked: nil).titleKey.text))
                                .tag(CallAppMode?.none)
                            ForEach(CallAppMode.allCases, id: \.self) { m in Text(m.titleKey.text).tag(CallAppMode?.some(m)) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            } label: {
                HintedRow(title: L10nKey.settingsAppsHeader.text, hint: summary) { EmptyView() }
            }
        }
        .disabled(model.data.meetingSettings.callMode == .off)
    }

    // MARK: Permissions

    private var permissions: some View {
        Section {
            ForEach(model.data.permissions) { item in
                PermissionRow(item: item) { model.actions.openPermissionPane(item.pane) }
            }
        } header: {
            Text(L10nKey.settingsPermissions.text)
        } footer: {
            Text(L10nKey.settingsPermissionsFooter.text)
        }
    }

    // MARK: General

    private var general: some View {
        Section {
            Toggle(L10nKey.settingsLogin.text, isOn: model.startAtLogin)
            HintedRow(title: L10nKey.settingsEngine.text) {
                if model.data.about.engineRunning {
                    Label(L10nKey.settingsEngineRunning.text, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label(L10nKey.settingsEngineDown.text, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            HintedRow(title: L10nKey.settingsVersion.text(model.data.about.version)) {
                Button(L10nKey.settingsCheckUpdates.text) { model.actions.checkForUpdates() }
            }
        } header: {
            Text(L10nKey.settingsGeneral.text)
        } footer: {
            PrivacyLine().padding(.top, 4)
        }
    }
}

/// A switch with a line under its title.
private struct ToggleRow: View {
    let title: String
    let hint: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn).labelsHidden()
        }
    }
}

/// A permission: a status icon, what it is for, whether it works, and the button that opens its page.
private struct PermissionRow: View {
    let item: PermissionItem
    let fix: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.titleKey.text)
                Text(item.whyKey.text).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            state
            if item.state == .needsAttention {
                Button(L10nKey.permFix.text, action: fix).buttonStyle(.borderedProminent)
            } else {
                Button(L10nKey.permOpenSettings.text, action: fix)
            }
        }
    }

    @ViewBuilder private var state: some View {
        switch item.state {
        case .allowed:
            Label(L10nKey.permAllowed.text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .needsAttention:
            Label(L10nKey.permAttention.text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .unknown:
            Label(L10nKey.permUnknown.text, systemImage: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}

/// The name in transcripts. It is typed into a draft of its own and saved when the user presses Return or leaves the
/// field, so a space at the end survives ("Anna " before "Karenina"), and a reload never overwrites what is being typed.
private struct NameField: View {
    let saved: String
    let fallback: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft, prompt: Text(fallback))
            .labelsHidden().multilineTextAlignment(.trailing).frame(width: 220)
            .focused($focused)
            .onAppear { draft = saved }
            // The field stops at the daemon's label cap: what is typed is what a transcript will say.
            .onChange(of: draft) { new in let cut = MeetingLimits.cap(new, to: MeetingLimits.labelMax); if cut != new { draft = cut } }
            .onSubmit { commit(draft) }
            // A name typed and then left by a click on another section is saved, not lost.
            .onDisappear { commit(draft) }
            .onChange(of: focused) { isFocused in if !isFocused { commit(draft) } }
            .onChange(of: saved) { new in if !focused { draft = new } }
    }
}
