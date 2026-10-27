import DictationCore
import Foundation

/// Sample data for the window: the prototype's content and the screenshot harness's. Nothing here
/// reads the daemon, UserDefaults or macOS. The call texts follow `ru`, because the notes of a
/// Russian call are written in Russian.
public enum PreviewData {
    public static func make(now: Date = Date(), ru: Bool = L10nBundle.locale.identifier.hasPrefix("ru"),
                            calendar: Calendar = .current) -> MainWindowData {
        func at(daysAgo: Int, hour: Int, minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        let zoom = zoomCall(ru: ru, started: at(daysAgo: 0, hour: 14, minute: 30))
        let meetings: [MeetingInfo] = [
            MeetingInfo(id: "m6", title: "Teams call", started: at(daysAgo: 0, hour: 17, minute: 5), status: .summarizing,
                        durationSeconds: 18 * 60),
            zoom.info.withoutTexts(),
            MeetingInfo(id: "m4", title: "Google Meet call", started: at(daysAgo: 1, hour: 11, minute: 0), status: .done,
                        durationSeconds: 65 * 60),
            MeetingInfo(id: "m3", title: "", started: at(daysAgo: 1, hour: 9, minute: 15), status: .transcribed,
                        notesPending: "model_missing", durationSeconds: 7 * 60),
            MeetingInfo(id: "m5", title: "OxPulse call", started: at(daysAgo: 3, hour: 16, minute: 40), status: .done,
                        audioDeleted: true, durationSeconds: 25 * 60),
            MeetingInfo(id: "m2", title: "Zoom call", started: at(daysAgo: 6, hour: 10, minute: 0), status: .failed,
                        error: "the recording was empty", durationSeconds: 12 * 60),
            MeetingInfo(id: "m1", title: "Google Meet call", started: at(daysAgo: 11, hour: 15, minute: 20), status: .done,
                        durationSeconds: 33 * 60),
            MeetingInfo(id: "m0", title: "Teams call", started: at(daysAgo: 17, hour: 13, minute: 0), status: .done,
                        durationSeconds: 51 * 60),
        ]
        var details: [String: MeetingDetail] = [zoom.info.id: zoom]
        // A call where the notes writer was missing: transcript only.
        var late = meetings[3]
        late.transcriptMD = transcript(ru: ru, short: true)
        details[late.id] = MeetingDetail(info: late, speakers: SpeakersState(mode: "", split: false, speakers: [
            SpeakerInfo(id: "them", name: "", label: ru ? "Собеседник" : "Other", speechSeconds: 190),
        ]))
        return MainWindowData(
            meetings: meetings, details: details, recordingElapsed: nil,
            meetingSettings: MeetingSettingsValues(
                enabled: true, autoStart: true,
                apps: CallPolicy.defaultApps(),
                folderPath: "~/Documents/ox-say Meetings", retention: .month,
                yourName: "", yourNameFallback: ru ? "Алексей Морозов" : "Alex Morgan", notesWriter: .ready),
            permissions: PermissionModel.items(microphone: .authorized, accessibility: true, notifications: .denied),
            dictation: DictationValues(
                keyTitle: "⌃Space", mode: .hold, sound: .lowerAllSound,
                recent: ru
                    ? ["Напомни, пожалуйста, что созвон с Анной перенесли на четверг, на три часа дня.",
                       "Добавь в список покупок: молоко, хлеб и батарейки для пульта.",
                       "Спасибо за быстрый ответ, посмотрю документ вечером и напишу вам завтра.",
                       "Встреча с командой в понедельник в десять утра."]
                    : ["Please remind me that the call with Anna moved to Thursday at three in the afternoon.",
                       "Add to the shopping list: milk, bread and batteries for the remote.",
                       "Thanks for the quick reply, I will read the document tonight and write back tomorrow.",
                       "Team meeting on Monday at ten in the morning."]),
            voices: VoicesValues(
                voices: ["Anna", "Studio Mara", ru ? "Тёплый рассказчик" : "Warm narrator"],
                russianVoice: "Anna", englishVoice: nil),
            about: AboutValues(version: "0.2.0", engineRunning: true, startAtLogin: true))
    }

    /// The same data with a recording running now.
    public static func recording(now: Date = Date(), ru: Bool = L10nBundle.locale.identifier.hasPrefix("ru")) -> MainWindowData {
        var d = make(now: now, ru: ru)
        d.recordingElapsed = 12 * 60 + 34
        return d
    }

    // MARK: the sample call

    private static func zoomCall(ru: Bool, started: Date) -> MeetingDetail {
        let info = MeetingInfo(
            id: "m7", title: "Zoom call", started: started, status: .done,
            notesMD: notes(ru: ru), transcriptMD: transcript(ru: ru, short: false),
            voiceMode: "auto", durationSeconds: 42 * 60)
        let speakers = SpeakersState(mode: "auto", split: true, speakers: [
            SpeakerInfo(id: "them:1", name: ru ? "Анна" : "Anna", label: ru ? "Анна" : "Anna", speechSeconds: 14 * 60,
                        sample: ru ? "Давайте начнём со страницы с ценами, там остались две правки…"
                                   : "Let's start with the pricing page, there are two changes left…"),
            SpeakerInfo(id: "them:2", name: ru ? "Борис" : "Boris", label: ru ? "Борис" : "Boris", speechSeconds: 9 * 60,
                        sample: ru ? "Оплату я проверю на настоящей карте до пятницы."
                                   : "I'll test the payment on a real card before Friday."),
            SpeakerInfo(id: "them:3", name: "", label: ru ? "Собеседник 3" : "Speaker 3", speechSeconds: 3 * 60,
                        sample: ru ? "А для русской версии сайта нужна отдельная политика?"
                                   : "Do we need a separate privacy note for the Russian site?"),
        ])
        return MeetingDetail(info: info, speakers: speakers)
    }

    private static func notes(ru: Bool) -> String {
        ru ? """
        # Zoom call

        ## Кратко

        Команда договорилась выпустить новый онбординг 12 ноября. Анна закончит страницу с ценами, Борис проверит оплату, письмо о запуске уйдёт за неделю до выхода.

        ## Решения

        - Выпускаем онбординг 12 ноября
        - Бесплатный тариф ограничиваем тремя проектами

        ## Задачи

        - [ ] Анна — Закончить страницу с ценами — в пятницу
        - [ ] Борис — Проверить оплату на настоящей карте — 5 ноября
        - [ ] Вы — Написать письмо о запуске — 7 ноября

        ## Открытые вопросы

        - Нужна ли отдельная политика конфиденциальности для русской версии сайта?
        """ : """
        # Zoom call

        ## Summary

        The team agreed to ship the new onboarding on 12 November. Anna will finish the pricing page, Boris will check the payment flow, and the launch email goes out a week before.

        ## Decisions

        - Ship the onboarding on 12 November
        - Limit the free plan to three projects

        ## Action items

        - [ ] Anna — Finish the pricing page — Friday
        - [ ] Boris — Test the payment flow on a real card — 5 November
        - [ ] You — Write the launch email — 7 November

        ## Open questions

        - Do we need a separate privacy note for the Russian site?
        """
    }

    private static func transcript(ru: Bool, short: Bool) -> String {
        let you = ru ? "Вы" : "You"
        let anna = ru ? "Анна" : "Anna"
        let boris = ru ? "Борис" : "Boris"
        let s3 = ru ? "Собеседник 3" : "Speaker 3"
        var lines: [String]
        if ru {
            lines = [
                "**\(you)** [0:04]: Всем привет, давайте начнём. Главное сегодня — дата выхода онбординга.",
                "**\(anna)** [0:19]: Давайте начнём со страницы с ценами, там остались две правки. Я закончу её к пятнице.",
                "**\(boris)** [0:41]: Оплату я проверю на настоящей карте до пятницы. Тестовый режим всё не покрывает.",
                "**\(you)** [1:02]: Хорошо. Тогда выпускаем двенадцатого ноября, а письмо о запуске я напишу седьмого.",
                "**\(s3)** [1:30]: А для русской версии сайта нужна отдельная политика конфиденциальности?",
                "**\(anna)** [1:48]: Хороший вопрос, пока не знаю. Оставим открытым.",
                "**\(you)** [2:10]: Бесплатный тариф ограничиваем тремя проектами, все согласны?",
                "**\(boris)** [2:21]: Согласен.",
            ]
        } else {
            lines = [
                "**\(you)** [0:04]: Hi everyone, let's get started. The main thing today is the date for the new onboarding.",
                "**\(anna)** [0:19]: Let's start with the pricing page, there are two changes left. I'll finish it by Friday.",
                "**\(boris)** [0:41]: I'll test the payment on a real card before Friday. Test mode doesn't cover everything.",
                "**\(you)** [1:02]: Good. Then we ship on 12 November, and I'll write the launch email on the 7th.",
                "**\(s3)** [1:30]: Do we need a separate privacy note for the Russian site?",
                "**\(anna)** [1:48]: Good question, I don't know yet. Let's leave it open.",
                "**\(you)** [2:10]: We limit the free plan to three projects, is everyone fine with that?",
                "**\(boris)** [2:21]: Fine with me.",
            ]
        }
        if short { lines = Array(lines.prefix(3)) }
        return "# Zoom call\n\n" + lines.joined(separator: "\n\n") + "\n"
    }
}

extension MeetingInfo {
    /// The list rows come without the texts, as the daemon's list answers.
    func withoutTexts() -> MeetingInfo {
        var copy = self
        copy.notesMD = nil
        copy.transcriptMD = nil
        return copy
    }
}
