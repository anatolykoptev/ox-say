import AppKit
import AVFoundation
import DictationCore
import MainWindowUI
import UniformTypeIdentifiers

/// The Расшифровка page's glue: it builds the daemon calls for `TranscribeSession` (which decides everything), measures a
/// picked file, runs the save panel and the pasteboard, and copies the session into the window's values. No decision lives
/// here, so nothing here is tested beyond the wiring pins; the behaviour is in DictationCore.
///
/// An upload outlives the window: the task lives here, not in the page, and nothing in this class cancels it. A window
/// that opens again finds the row working, or the new transcript in the list.
@MainActor
final class TranscribeSource {
    private let model: MainWindowModel
    private let host: MainWindowHost
    private let session: TranscribeSession

    init(model: MainWindowModel, host: MainWindowHost) {
        self.model = model
        self.host = host
        let client = host.client
        session = TranscribeSession(ops: TranscribeOps(
            list: { try await client.transcripts() },
            transcribe: { url, title, seconds in
                // The daemon's last /status is app state: read it on the main actor, the upload itself runs off it.
                let limits = await MainActor.run { TranscribeLimits(status: host.daemonStatus()) }
                return try await client.transcribeFile(url, title: title, engine: nil, language: nil, prompt: nil, seconds: seconds,
                                                       limits: limits)
            },
            text: { id, format in try await client.transcriptText(id: id, format: format) },
            delete: { id in try await client.deleteTranscript(id: id) },
            duration: { url in
                let seconds = try? await AVURLAsset(url: url).load(.duration).seconds
                return seconds?.isFinite == true ? seconds : nil
            }), limits: { TranscribeLimits(status: host.daemonStatus()) })
        session.onChange = { [weak self] in self?.sync() }
    }

    /// A file is being uploaded or transcribed: the version handshake waits.
    var transcribing: Bool { session.working != nil }

    private func sync() {
        model.data.transcribe = TranscribeValues(entries: session.entries, load: session.load, working: session.working,
                                                 selectedID: session.selectedID)
    }

    func reload() {
        Task { @MainActor in await session.reload() }
    }

    /// A file picked or dropped. The app is not sandboxed, so the path reads without a security scope.
    func pick(_ url: URL) {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        Task { @MainActor in
            if let sentence = await session.submit(url, bytes: bytes) { model.data.notice = sentence }
        }
    }

    func select(_ id: String) { session.select(id) }

    /// «Копировать»: the plain text onto the pasteboard, by the person's own click.
    func copy(_ id: String) {
        Task { @MainActor in
            do {
                let file = try await session.file(id: id, format: .text)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(decoding: file.data, as: UTF8.self), forType: .string)
                model.data.notice = L10nKey.transcribeCopied.text
            } catch {
                model.data.notice = session.sentence(error)
            }
        }
    }

    /// «Сохранить…», «Субтитры»: the daemon's document in `format`, written where the save panel says.
    func save(_ id: String, _ format: TranscriptFormat) {
        Task { @MainActor in
            do {
                let file = try await session.file(id: id, format: format)
                host.saveFile(file) { [weak self] saved in
                    if !saved { self?.model.data.notice = L10nKey.transcribeSaveFailed.text }
                }
            } catch {
                model.data.notice = session.sentence(error)
            }
        }
    }

    /// The page has already asked; this deletes.
    func delete(_ id: String) {
        Task { @MainActor in
            if let sentence = await session.delete(id: id) {
                model.data.notice = sentence
                await session.reload()
            }
        }
    }
}

/// The save panel of the Расшифровка page, a sheet on the main window; the person's own act writes the file.
enum TranscriptSave {
    @MainActor
    static func present(_ file: TranscriptFile, in window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = UTType(filenameExtension: (file.name as NSString).pathExtension).map { [$0] } ?? []
        panel.nameFieldStringValue = file.name
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        let write: (NSApplication.ModalResponse) -> Void = { response in
            // A cancelled panel is nothing to report; only a write that was asked for can fail.
            if let saved = file.finishSave(confirmed: response == .OK, url: panel.url) { completion(saved) }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            panel.begin(completionHandler: write)
        }
    }
}
