import Foundation

/// The words of the update and install alerts, in the user's language: `text` resolves a key (the bundle's by
/// default, the shipped strings in tests). The decisions behind them are UpdatePrompt, UpdateGate and UpdateInstaller.
public struct UpdateDialog: Equatable {
    public var title: String
    public var text: String
    public var buttons: [String]
}

public enum UpdateDialogs {
    public typealias Text = (L10nKey) -> String
    private static func fill(_ key: L10nKey, _ text: Text, _ args: String...) -> String {
        String(format: text(key), arguments: args)
    }

    /// An install is already running: Check for Updates, Repair and Install Studio Voice say so.
    public static func busy(text: Text = { $0.text }) -> UpdateDialog {
        UpdateDialog(title: UpdateGate.busyAlertTitle(text: text), text: UpdateGate.busyAlertText(text: text), buttons: [text(.commonOk)])
    }

    /// Reinstalling the version already on disk because the service runs another.
    public static func repair(target: String, text: Text = { $0.text }) -> UpdateDialog {
        UpdateDialog(title: text(.updateRepairTitle), text: fill(.updateRepairText, text, target),
                     buttons: [text(.updateRepairButton), text(.commonCancel)])
    }

    public static func studioVoice(text: Text = { $0.text }) -> UpdateDialog {
        UpdateDialog(title: text(.updateStudioTitle), text: text(.updateStudioText),
                     buttons: [text(.updateStudioButton), text(.commonCancel)])
    }

    /// The manual check's answer.
    public static func prompt(_ prompt: UpdatePrompt, text: Text = { $0.text }) -> UpdateDialog {
        switch prompt {
        case .upToDate(let version):
            return UpdateDialog(title: text(.updateUptodateTitle), text: fill(.updateUptodateText, text, version), buttons: [text(.commonOk)])
        case .developmentBuild(let version):
            return UpdateDialog(title: text(.updateDevTitle), text: fill(.updateDevText, text, version), buttons: [text(.commonOk)])
        case .failed(let reason):
            return UpdateDialog(title: text(.updateCheckFailedTitle), text: reason, buttons: [text(.commonRetry), text(.commonOk)])
        case .available(let remote, let local, let notes, let url):
            let have = fill(.updateAvailableHave, text, local)
            return UpdateDialog(title: fill(.updateAvailableTitle, text, remote),
                                text: notes.isEmpty ? have : "\(have)\n\n\(notes)",
                                buttons: [text(.updateAvailableUpdate), text(.updateAvailableLater)]
                                    + (url == nil ? [] : [text(.updateAvailableNotes)]))
        }
    }
}
