import AppKit
import DictationCore
import UniformTypeIdentifiers

/// What the Reel editor asks of the app around it: the daemon calls, the
/// stored Russian pick and a modal alert. The same seam StudioHost is.
struct ReelHost {
    var client: StudioClient
    var speech: SpeechClient
    /// The Russian voice pick of the Voice menu, preselected in the picker.
    var russianVoicePick: () -> String?
    /// Shows a modal alert over every app and returns the pressed button.
    var alert: (_ title: String, _ text: String, _ buttons: [String]) -> NSApplication.ModalResponse
}

/// The «Ролик» detail's state and daemon traffic: the script editor, the
/// voice pick, the one voiceover it may run at a time with its per-phrase
/// progress, and the export of the finished WAV. Every rule it can decide
/// without AppKit lives in DictationCore (ReelScript, ScriptLimit).
@MainActor final class ReelModel: ObservableObject {
    /// The script being edited — the phrases come straight out of this text.
    @Published var editorText = ""
    /// The daemon's last /status, as the Studio menu models it.
    @Published private(set) var service = StudioMenu.ServiceState.unknown
    /// The voice picker's entries; index 0 is nil — the daemon's own pick.
    @Published private(set) var voiceNames: [String?] = [nil]
    @Published var voiceIndex = 0
    /// The voiceover being followed (created here or picked up).
    @Published private(set) var job: ProduceJob?
    /// The last poll got no answer: `job` may be out of date.
    @Published private(set) var serviceWaiting = false
    /// The phrases the followed job was created from — the user's own text,
    /// or the chunk texts regrouped by paragraph for a job picked up.
    @Published private(set) var phrases: [String] = []
    /// Per phrase, whether it speaks at all (ReelScript.emits).
    @Published private(set) var emitting: [Bool] = []
    /// Chunk index -> script paragraph, from the chunks/{n} details.
    @Published private(set) var paragraphOf: [Int: Int] = [:]
    /// A create is being asked of the daemon.
    @Published private(set) var creating = false
    /// A document is being read; the editor fills when it lands.
    @Published private(set) var readingDocument = false
    /// The last problem worth a line under the button (a refusal, a 409).
    @Published var notice: String?

    /// How often /status is re-asked while the window is open.
    static let statusPollSeconds: TimeInterval = 10

    private let host: ReelHost
    /// The poller of the followed job, built on first use so its callbacks
    /// can capture self — AppDelegate's plain lazy var can run this init.
    private lazy var follower = VoiceoverFollower(
        source: VoiceoverFollower.Source(
            voiceover: { [client = host.client] in try await client.voiceover(id: $0) },
            voiceovers: { [client = host.client] in try await client.voiceovers() }),
        onChange: { [weak self] in self?.refresh() },
        onFinish: { [weak self] _ in self?.refresh() })
    private var pollTask: Task<Void, Never>?
    private var voices: [String]?
    private var didPresetVoice = false
    /// The job this window created; its phrases stay the user's own text.
    private var createdJobID: String?
    /// The job `paragraphOf` and `chunkDetails` belong to — synced when every
    /// one of its chunk indices holds a paragraph (ReelScript.missingChunks).
    private var detailsJobID: String?
    /// The details fetched so far for `detailsJobID`; a picked-up job's
    /// phrases rebuild from them as each round lands.
    private var chunkDetails: [ProduceChunkDetail] = []
    private var detailsInFlight = false

    /// The init only stores its dependencies — everything the follower drives
    /// stays @MainActor — so AppDelegate's plain lazy var can build it.
    nonisolated init(host: ReelHost) {
        self.host = host
    }

    // MARK: what the view asks

    /// The phrases of the text as it stands — the count the editor shows.
    var phraseCount: Int { ReelScript.phrases(of: editorText).count }

    /// A voiceover is going: followed and not over, or being asked of the daemon.
    var jobActive: Bool {
        creating || (job.map { !$0.status.isTerminal } ?? false)
    }

    /// «Озвучить»: the pure rule plus "a document is not mid-read".
    var canCreate: Bool {
        !readingDocument && ReelScript.canCreate(script: editorText, studioAvailable: studioAvailable, jobRunning: jobActive)
    }

    /// One row per phrase of the followed job: number, preview, state.
    var rows: [PhraseRow] {
        let states = ReelScript.phraseStates(emitting: emitting, chunks: job?.chunks ?? [], paragraphOf: paragraphOf)
        return states.enumerated().map { PhraseRow(index: $0, preview: ReelScript.preview(phrases[$0]), state: $1) }
    }

    /// Why «Озвучить» stays grey — the service's side of the story, or nil
    /// when nothing needs saying (a running job explains itself in progress).
    var blockReason: String? {
        switch service {
        case .unknown: return L10nKey.reelChecking.text
        case .unreachable: return L10nKey.reelServiceMissing.text
        case .answered(let status):
            guard !status.studioAvailable else { return nil }
            return ReelText.unavailableText(reason: status.studioReason) { $0.text }
        }
    }

    private var studioAvailable: Bool {
        if case .answered(let status) = service { return status.studioAvailable }
        return false
    }

    // MARK: lifecycle

    /// The window is on screen: start asking /status, and pick the job's
    /// polling back up. A live follow resumes; anything running that this
    /// window does not know — started from the menu or while it was closed —
    /// is found by the pick-up the next answered /status runs.
    func appeared() {
        follower.resume()
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refreshService()
                try? await Task.sleep(nanoseconds: UInt64(Self.statusPollSeconds * 1_000_000_000))
            }
        }
    }

    func disappeared() {
        pollTask?.cancel()
        pollTask = nil
        follower.stop()
    }

    /// /status: remembers the answer, feeds the follower's pick-up of a job
    /// already running, and fetches the voices once.
    private func refreshService() async {
        let status = try? await host.client.status()
        service = status.map { .answered($0) } ?? .unreachable
        guard status != nil else { return }
        follower.serviceAnswered()
        if voices == nil { await refreshVoices() }
    }

    private func refreshVoices() async {
        guard let list = try? await host.speech.voices() else { return }
        voices = list
        let choices = StudioMenu.voiceChoices(voices: list, russianPick: host.russianVoicePick())
        voiceNames = choices.names
        if !didPresetVoice {
            voiceIndex = choices.selected
            didPresetVoice = true
        } else if voiceIndex >= voiceNames.count {
            voiceIndex = 0
        }
    }

    /// The follower reported: republish the job and make sure its chunk
    /// details (the chunk -> paragraph map) are fetched once.
    private func refresh() {
        job = follower.job
        serviceWaiting = follower.serviceWaiting
        if let job { syncDetails(job) }
    }

    /// Fetches the chunk details the followed job is still missing — the ones
    /// `ReelScript.missingChunks` names — one round per poll, never a tight
    /// retry loop. A fetch that fails leaves its index missing and the next
    /// status poll asks for it again; the job is synced only when nothing is
    /// missing. A job this window did not create also gets its phrases rebuilt
    /// from the chunks' own text, growing as each round lands.
    private func syncDetails(_ job: ProduceJob) {
        if detailsJobID != job.id {
            detailsJobID = job.id
            paragraphOf = [:]
            chunkDetails = []
        }
        let missing = ReelScript.missingChunks(of: job, paragraphOf: paragraphOf)
        guard !missing.isEmpty, !detailsInFlight else { return }
        detailsInFlight = true
        let client = host.client
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.detailsInFlight = false }
            var fetched: [ProduceChunkDetail] = []
            for n in missing {
                if let detail = try? await client.voiceoverChunk(id: job.id, n: n) {
                    fetched.append(detail)
                }
            }
            guard self.detailsJobID == job.id else { return }
            self.chunkDetails += fetched
            self.paragraphOf.merge(fetched.map { ($0.index, $0.paragraph) }) { _, last in last }
            if job.id != self.createdJobID {
                self.phrases = Self.phrases(fromChunks: self.chunkDetails)
                self.emitting = [Bool](repeating: true, count: self.phrases.count)
            }
        }
    }

    /// The phrases of a job picked up: the chunks' spoken text regrouped by
    /// paragraph, laid out so position i IS paragraph i — a paragraph whose
    /// chunks failed to fetch keeps its index and shows empty, pending.
    private static func phrases(fromChunks details: [ProduceChunkDetail]) -> [String] {
        let grouped = Dictionary(grouping: details, by: \.paragraph)
        let count = (details.map(\.paragraph).max() ?? -1) + 1
        return (0..<count).map { paragraph in
            (grouped[paragraph] ?? []).sorted { $0.index < $1.index }.map(\.text).joined(separator: " ")
        }
    }

    // MARK: actions

    /// «Открыть документ…»: the same read the Studio menu does — panel,
    /// DocumentReader, ScriptCleaner — into the editor, in the window's own
    /// words.
    func openDocument() {
        guard let file = StudioForms.chooseDocument(title: L10nKey.reelChooseTitle.text,
                                                    message: L10nKey.reelChooseMessage.text) else { return }
        readingDocument = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.readingDocument = false }
            do {
                let document = try await DocumentReader.read(file)
                let script = document.script
                if script.isEmpty {
                    _ = self.host.alert(L10nKey.reelNothingToRead.text,
                                        ReelText.emptyMessage(of: document) { $0.text }, ["OK"])
                } else {
                    self.editorText = script
                }
            } catch {
                _ = self.host.alert(L10nKey.reelReadError.text,
                                    ReelText.documentError(error) { $0.text }, ["OK"])
            }
        }
    }

    /// «Озвучить»: the plan's create — one take, the reference clone path,
    /// the reels preset, a title from the first phrase.
    func create() {
        guard canCreate else { return }
        let script = ScriptLimit.script(from: editorText)
        let voice = voiceIndex < voiceNames.count ? voiceNames[voiceIndex] : nil
        creating = true
        notice = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.creating = false }
            do {
                let job = try await self.host.client.startVoiceover(
                    script: script, title: ReelScript.title(of: script), voice: voice,
                    format: .short, takes: ReelScript.takes, cloneMode: ReelScript.cloneMode)
                self.createdJobID = job.id
                self.phrases = ReelScript.phrases(of: script)
                self.emitting = self.phrases.map(ReelScript.emits)
                self.paragraphOf = [:]
                self.chunkDetails = []
                self.detailsJobID = nil
                self.follower.follow(job)
            } catch {
                // A 409 — "another voiceover is running" — lands here as the
                // daemon's own plain-words message behind the lead-in.
                self.notice = ReelText.notice(error) { $0.text }
            }
        }
    }

    /// «Остановить»: the same confirm-and-cancel the Studio menu runs.
    func stop() {
        guard let job else { return }
        let sure = host.alert(L10nKey.reelStopTitle.text, L10nKey.reelStopText.text,
                              [L10nKey.reelStopConfirm.text, L10nKey.reelKeepGoing.text])
        guard sure == .alertFirstButtonReturn else { return }
        Task { @MainActor [weak self] in
            do {
                try await self?.host.client.stopVoiceover(id: job.id)
            } catch {
                self?.notice = ReelText.notice(error) { $0.text }
            }
        }
    }

    /// The paused-on-battery job's way out, the same call the menu offers.
    func continueOnBattery() {
        guard let job else { return }
        Task { @MainActor [weak self] in
            do {
                try await self?.host.client.continueOnBattery(id: job.id)
            } catch {
                self?.notice = ReelText.notice(error) { $0.text }
            }
        }
    }

    /// «Экспорт WAV…»: the published file copied where the person says. The
    /// panel is the destination picker — nothing is written elsewhere.
    func export() {
        guard let path = job?.outputPath else { return }
        let source = URL(fileURLWithPath: path)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "wav")].compactMap { $0 }
        panel.nameFieldStringValue = source.lastPathComponent
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        // A folder is never a destination — clearing the way would delete it.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
           !ReelExport.allowsDestination(isDirectory: isDirectory.boolValue) {
            _ = host.alert(L10nKey.reelExportError.text, L10nKey.reelExportFolder.text, ["OK"])
            return
        }
        // Copy to a staging file next to the destination, then swap atomically:
        // a failed copy leaves the file the person had there intact.
        let staging = ReelExport.stagingURL(for: destination)
        do {
            try FileManager.default.copyItem(at: source, to: staging)
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            _ = host.alert(L10nKey.reelExportError.text, error.localizedDescription, ["OK"])
        }
    }

    /// «Показать в Finder»: selects the published file in its folder.
    func reveal() {
        guard let path = job?.outputPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
