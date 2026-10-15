import AppKit
import AVFoundation
import DictationCore

/// The standard About panel with the app's own details: version and copyright
/// from the bundle, the service version, both permissions and a link to the
/// project. Only reads state; it never prompts for a permission.
enum AboutPanel {
    static let creditsFontSize: CGFloat = 11
    static let applicationName = "OxSay"

    /// The bundle's short version, what the menu footer and the panel both show.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func show(serviceVersion: String?) {
        let lines = AboutInfo.lines(
            serviceVersion: serviceVersion,
            microphoneAllowed: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibilityAllowed: AXIsProcessTrusted())
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: applicationName,
            .applicationVersion: appVersion,
            .version: "", // no build number after the version: it equals the version
            .applicationIcon: NSApp.applicationIconImage as Any,
            .credits: credits(lines),
        ])
    }

    /// Small centred text: the lines, then the project link.
    private static func credits(_ lines: [String]) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: creditsFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
        let text = NSMutableAttributedString(string: lines.joined(separator: "\n") + "\n", attributes: base)
        var link = base
        link[.link] = URL(string: AboutInfo.repositoryURL)
        text.append(NSAttributedString(string: AboutInfo.repositoryURL, attributes: link))
        return text
    }
}
