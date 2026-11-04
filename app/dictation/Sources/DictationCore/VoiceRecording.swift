import Foundation

/// «Записать свой голос»: the guided recording behind the sheet on the Voices page. A value type; the app
/// (VoiceSource) owns the microphone, the timer, the take's samples and the daemon call, and carries out the
/// `Effect` a step returns. Every decision is here: when the microphone is asked, how long a take must be, when it
/// stops itself, what a meeting recording does to it and what «Сохранить» sends.
public struct VoiceRecording: Equatable {
    public enum Phase: Equatable {
        case ready
        /// `denied: false` — the macOS question is on screen (asked once, waiting); `true` — the person said no, so the
        /// sheet offers System Settings and no Record button.
        case needsMicrophone(denied: Bool)
        case recording
        case review(seconds: Double)
        case saving
        case saved(String)
        case failed(String)
    }

    /// What the app must do after a step.
    public enum Effect: Equatable {
        /// Raise the macOS microphone prompt (the first «Записать»).
        case askMicrophone
        /// Start the recorder (24 kHz) and its timer.
        case startRecorder
        /// The take ended by itself: stop the recorder and keep its samples for the review.
        case stopRecorder
        /// Stop the recorder if it runs and drop the samples: the take is thrown away.
        case discardTake
    }

    /// What «Сохранить» sends: the fields of POST /v1/audio/voices except the audio path (the app writes the take).
    public struct Request: Equatable {
        public var id: String
        public var label: String
        /// The passage that was read aloud: the clone engines use it as the in-context transcript.
        public var refText: String
        public var source: String
    }

    public static let minimumSeconds = 5.0, maximumSeconds = 20.0, sampleRate = 24000

    public private(set) var phase: Phase = .ready
    public private(set) var promptIndex = 0
    public let language: String
    /// The live length of the take in progress, from the app's timer.
    public private(set) var seconds: Double = 0
    public private(set) var label: String
    /// Why the last «Сохранить» did not go through, or the daemon's own sentence. The take stays.
    public private(set) var problem: String?
    private var asked = false
    private var microphone: PermissionAuth?

    public init(language: String, text: (L10nKey) -> String = { $0.text }) {
        self.language = language
        label = text(.voiceRecordLabelDefault)
    }

    // MARK: prompts

    /// Three passages to read aloud, 12-18 s each at reading pace; Russian for a Russian window, English otherwise.
    public static func prompts(language: String) -> [String] {
        language.hasPrefix("ru") ? russian : english
    }

    private static let english = [
        "The morning light came slowly through the kitchen window while I made tea and listened to the rain. Nothing was urgent yet, and for a few quiet minutes the whole day felt like it belonged to me.",
        "My grandfather used to say that a good story needs three things: a long road, an honest friend, and a surprise waiting at the very end. I still think about that every time I start telling one.",
        "Please call me back when you get this message. I found the keys, the tickets are booked for Thursday, and we can leave early if the weather stays clear. Let me know what time works for you.",
    ]

    private static let russian = [
        "Утренний свет медленно пробирался через кухонное окно, пока я заваривал чай и слушал дождь. Ничего срочного ещё не было, и несколько тихих минут весь день казался только моим.",
        "Мой дедушка говорил, что в хорошей истории должно быть три вещи: долгая дорога, верный друг и неожиданность, которая ждёт в самом конце. Я вспоминаю его слова каждый раз, когда начинаю рассказывать.",
        "Перезвони мне, пожалуйста, как получишь сообщение. Ключи я нашёл, билеты на четверг куплены, и мы сможем выехать пораньше, если погода не испортится. Напиши, во сколько тебе удобно.",
    ]

    /// The passage on screen, the one that is stored as the voice's reference text.
    public var prompt: String {
        let all = Self.prompts(language: language)
        return all[promptIndex % all.count]
    }

    /// «Другой текст»: the next passage, only while no take is running or kept.
    public mutating func nextPrompt() {
        switch phase {
        case .ready, .failed: promptIndex = (promptIndex + 1) % Self.prompts(language: language).count
        default: break
        }
    }

    // MARK: microphone

    /// What macOS says about the microphone right now. Undecided asks (once) and waits; denied shows the Settings link;
    /// allowed opens the Record button. A take on screen is not touched by a read.
    public mutating func micStatus(_ status: PermissionAuth) -> Effect? {
        microphone = status
        switch phase {
        case .recording, .review, .saving, .saved: return nil
        case .ready, .needsMicrophone, .failed: break
        }
        switch status {
        case .authorized:
            if case .needsMicrophone = phase { phase = .ready }
            return nil
        case .denied:
            phase = .needsMicrophone(denied: true)
            return nil
        case .notDetermined:
            phase = .needsMicrophone(denied: false)
            guard !asked else { return nil }
            asked = true
            return .askMicrophone
        }
    }

    public var showsRecordButton: Bool {
        if case .needsMicrophone = phase { return false }
        return true
    }

    public var showsSettingsLink: Bool { phase == .needsMicrophone(denied: true) }

    // MARK: a take

    /// «Записать» / «Записать ещё раз»: a new take, the last one gone. Refused (with the reason) while a meeting is
    /// being recorded — both need the microphone — and never before the microphone is known to be allowed.
    public mutating func start(meetingRecording: Bool = false, text: (L10nKey) -> String = { $0.text }) -> Effect? {
        switch phase {
        case .ready, .review, .failed: break
        case .needsMicrophone, .recording, .saving, .saved: return nil
        }
        guard microphone == .authorized else { return nil }
        if meetingRecording {
            phase = .failed(text(.voiceRecordBlockedMeeting))
            return nil
        }
        phase = .recording
        seconds = 0
        problem = nil
        return .startRecorder
    }

    /// «Остановить»: the app stopped the recorder; `seconds` is what it kept.
    public mutating func stop(seconds: Double) {
        guard phase == .recording else { return }
        self.seconds = seconds
        phase = .review(seconds: seconds)
    }

    /// The timer: the length so far. At the maximum the take ends by itself.
    public mutating func tick(seconds: Double) -> Effect? {
        guard phase == .recording else { return nil }
        if seconds >= Self.maximumSeconds {
            self.seconds = Self.maximumSeconds
            phase = .review(seconds: Self.maximumSeconds)
            return .stopRecorder
        }
        self.seconds = seconds
        return nil
    }

    /// The recorder could not start or died: the reason shows and a new take may start.
    public mutating func recorderFailed(_ sentence: String) {
        phase = .failed(sentence)
    }

    /// A meeting recording started: it needs the microphone, so a take in progress or kept is stopped and thrown away.
    public mutating func meetingStarted(text: (L10nKey) -> String = { $0.text }) -> Effect? {
        switch phase {
        case .recording, .review:
            phase = .failed(text(.voiceRecordMeetingStarted))
            return .discardTake
        default:
            return nil
        }
    }

    // MARK: saving

    /// The take is long enough to become a voice.
    public var canSave: Bool {
        if case .review(let seconds) = phase { return seconds >= Self.minimumSeconds }
        return false
    }

    /// The name as typed.
    public mutating func edit(label: String) {
        self.label = label
    }

    /// «Сохранить»: the request to send, or nil with `problem` set. `taken` holds ids and lower-cased labels of the
    /// library; the name rule is the other add sheets' (VoiceName.isTaken).
    public mutating func save(taken: Set<String>, text: (L10nKey) -> String = { $0.text }) -> Request? {
        guard case .review = phase else { return nil }
        guard canSave else {
            problem = String(format: text(.voiceRecordTooShort), Int(Self.minimumSeconds))
            return nil
        }
        guard let clean = VoiceLabel.clean(label) else {
            problem = text(.voicesRenameInvalid)
            return nil
        }
        if VoiceName.isTaken(clean, in: taken) {
            problem = text(.designProblemNameTaken)
            return nil
        }
        problem = nil
        phase = .saving
        return Request(id: VoiceName.id(from: clean, taken: taken), label: clean, refText: prompt, source: "recorded")
    }

    /// The daemon refused or failed: the take and the name stay, the sentence shows.
    public mutating func refused(_ sentence: String) {
        guard phase == .saving else { return }
        phase = .review(seconds: seconds)
        problem = sentence
    }

    public mutating func saved() {
        guard phase == .saving else { return }
        phase = .saved(VoiceLabel.clean(label) ?? label)
    }

    // MARK: closing

    /// The take is being sent: the sheet stays until the answer.
    public var mayClose: Bool { phase != .saving }

    /// Esc, or the sheet's close: a take in progress or kept is stopped and discarded.
    public mutating func escape() -> Effect? {
        switch phase {
        case .recording, .review: return .discardTake
        default: return nil
        }
    }

    // MARK: the meter

    /// The nine bars of the level meter. Static under Reduce Motion (the sheet shows the seconds instead).
    public static func meterBars(levels: [Float], reduceMotion: Bool) -> [Float] {
        let bars = 9
        guard !reduceMotion else { return Array(repeating: 0, count: bars) }
        return (0..<bars).map { $0 < levels.count ? min(1, max(0, levels[$0])) : 0 }
    }
}
