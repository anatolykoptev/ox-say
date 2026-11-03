import Foundation

/// «Взять из файла»: the picked clip and what the sheet types, while the add is decided and sent. A value type — the
/// app (VoiceSource) carries out what `submit` returns and writes the daemon's answer back in.
public struct VoiceFileAdd: Equatable {
    /// What «Добавить» sends when the form is valid: the fields of POST /v1/audio/voices except `source`.
    public struct Request: Equatable {
        public var id: String
        public var label: String
        public var audioPath: String
        public var refText: String
    }

    /// The picked clip as the app measured it: the name the sheet shows, the absolute path the daemon reads, the
    /// duration AVURLAsset reported (nil when it could not), the byte count and the extension.
    public let fileName: String
    public let audioPath: String
    public let seconds: Double?
    public let bytes: Int64
    public let ext: String
    /// Whether the daemon's studio voice is installed: past its encoder window the file is refused outright.
    public let studioInstalled: Bool

    /// The voice's name, as typed; starts as the file's name.
    public private(set) var label: String
    /// «Что говорится в записи», as typed; empty sends the clip to the speaker embedding alone.
    public private(set) var refText: String
    /// The add in flight: «Добавить» sends nothing while it lasts and the sheet may not close.
    public private(set) var sending = false
    /// Why the last «Добавить» did not go through — a refused check or the daemon's own sentence. The input stays.
    public private(set) var problem: String?

    public init(fileName: String = "", audioPath: String = "", seconds: Double? = nil, bytes: Int64 = 0,
                ext: String = "", studioInstalled: Bool = false) {
        self.fileName = fileName
        self.audioPath = audioPath
        self.seconds = seconds
        self.bytes = bytes
        self.ext = ext
        self.studioInstalled = studioInstalled
        label = (fileName as NSString).deletingPathExtension
        refText = ""
    }

    /// The file itself, checked eagerly: a refused file shows its sentence and «Добавить» stays off.
    public var fileProblem: String? {
        VoiceFileCheck.problem(seconds: seconds, bytes: bytes, ext: ext, studioInstalled: studioInstalled)
    }

    /// The clip is longer than what a voice keeps: a warning under the form, not a refusal.
    public var warning: String? {
        VoiceFileCheck.warning(seconds: seconds, studioInstalled: studioInstalled)
    }

    /// Esc, Cancel or the sheet's close: while the add is in flight it is not abandoned (a refused answer's sentence
    /// would land nowhere).
    public var mayClose: Bool { !sending }

    /// The form's text as it is typed, so Cancel keeps it.
    public mutating func edit(label: String, refText: String) {
        self.label = label
        self.refText = refText
    }

    /// «Добавить»: the request to send, or nil with `problem` set. A label naming an existing voice — by the id it
    /// slugs to, or by the label itself case-insensitively — is refused here; `taken` holds ids and lower-cased
    /// labels, the same rule «Описать словами» follows (VoiceDesignFlow.submit).
    public mutating func submit(taken: Set<String>, text: (L10nKey) -> String = { $0.text }) -> Request? {
        guard !sending else { return nil }
        if let found = VoiceFileCheck.problem(seconds: seconds, bytes: bytes, ext: ext,
                                              studioInstalled: studioInstalled, text: text) {
            problem = found
            return nil
        }
        guard let clean = VoiceLabel.clean(label) else {
            problem = text(.voicesRenameInvalid)
            return nil
        }
        if taken.contains(VoiceName.id(from: clean, taken: [])) || taken.contains(clean.lowercased()) {
            problem = text(.designProblemNameTaken)
            return nil
        }
        problem = nil
        sending = true
        return Request(id: VoiceName.id(from: clean, taken: taken), label: clean,
                       audioPath: audioPath,
                       refText: refText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The daemon refused or failed (400/409, its own plain sentence through StudioError.plain): the input stays.
    public mutating func refused(_ sentence: String) {
        sending = false
        problem = sentence
    }
}
