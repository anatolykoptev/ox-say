import DictationCore
import SwiftUI

/// Settings: meetings, permissions, general. One grouped Form; every row says what it does in
/// plain words, and a permission row says whether it works and opens the right System Settings page.
struct SettingsPage: View {
    @ObservedObject var model: MainWindowModel

    private var s: Binding<MeetingSettingsValues> { $model.data.meetingSettings }

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
                ToggleRow(title: L10nKey.menuMeetingAutoStart.text, hint: L10nKey.settingsAutoFooter.text,
                          isOn: s.autoStart)
                HintedRow(title: L10nKey.settingsFolder.text, hint: s.wrappedValue.folderPath) {
                    Button(L10nKey.commonChoose.text) { model.actions.chooseNotesFolder() }
                    Button(L10nKey.commonOpen.text) { model.actions.openNotesFolder() }
                }
                HintedRow(title: L10nKey.settingsKeep.text, hint: L10nKey.settingsKeepFooter.text) {
                    Picker("", selection: s.retention) {
                        ForEach(MeetingRetention.allCases, id: \.self) { Text($0.titleKey.text).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                HintedRow(title: L10nKey.settingsName.text) {
                    TextField("", text: s.yourName, prompt: Text(s.wrappedValue.yourNameFallback))
                        .labelsHidden().multilineTextAlignment(.trailing).frame(width: 220)
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
            case .missing:
                Text(L10nKey.settingsNotesWriterMissing.text).font(.callout).foregroundStyle(.secondary)
                Button(L10nKey.settingsNotesWriterDownload.text) { model.actions.downloadNotesWriter() }
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
        let apps = model.data.meetingSettings.apps
        let auto = apps.filter { $0.mode == .auto }.count
        let ask = apps.filter { $0.mode == .ask }.count
        return Section {
            DisclosureGroup(isExpanded: $model.appsExpanded) {
                ForEach(s.apps) { $app in
                    HintedRow(title: app.name, hint: app.noteKey?.text) {
                        Picker("", selection: $app.mode) {
                            ForEach(CallAppMode.allCases, id: \.self) { Text($0.titleKey.text).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            } label: {
                HintedRow(title: L10nKey.settingsAppsHeader.text,
                          hint: String(format: L10nKey.settingsAppsSummary.text, auto, ask)) { EmptyView() }
            }
        }
        .disabled(!model.data.meetingSettings.autoStart)
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
            Toggle(L10nKey.settingsLogin.text, isOn: $model.data.about.startAtLogin)
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
