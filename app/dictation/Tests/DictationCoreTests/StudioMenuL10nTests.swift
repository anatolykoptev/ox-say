import Foundation
import XCTest
@testable import DictationCore

/// A Russian user sees no English in the Studio voiceover flow, the status menu, its notices and the pills (#333).
/// The words are checked against the shipped en and ru strings, not against a stub.
final class StudioMenuL10nTests: XCTestCase {
    private let en = ShippedStrings.localizer("en")
    private let ru = ShippedStrings.localizer("ru")
    private var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }
    private func source(_ path: String) throws -> String { try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8) }
    private func job(_ status: ProduceStatus, title: String = "Глава", done: Int = 3, total: Int = 10, review: Int = 0,
                     error: String? = nil, wav: String? = nil) -> ProduceJob {
        ProduceJob(id: "j", title: title, status: status, partsTotal: total, partsDone: done, partsToReview: review, error: error, outputPath: wav)
    }

    func testTheStudioMenuRowsReadRightInBothLanguages() {
        XCTAssertEqual(StudioMenu.newVoiceoverTitle(text: en), "New Voiceover from Document…")
        XCTAssertEqual(StudioMenu.newVoiceoverTitle(text: ru), "Новая озвучка из документа…")
        XCTAssertEqual(StudioMenu.stopTitle(text: en), "Stop Voiceover")
        XCTAssertEqual(StudioMenu.stopTitle(text: ru), "Остановить озвучку")
        XCTAssertEqual(StudioMenu.continueTitle(text: ru), "Продолжить работу от батареи")
        XCTAssertEqual(StudioMenu.folderTitle(text: en), "Open Voiceovers Folder")
        XCTAssertEqual(StudioMenu.folderTitle(text: ru), "Открыть папку с озвучками")
        XCTAssertEqual(StudioMenu.noServiceTitle(text: en), "Studio needs the ox-say service, which is not answering")
        XCTAssertEqual(StudioMenu.noServiceTitle(text: ru), "Студии нужна служба ox-say, а она не отвечает")
        XCTAssertEqual(StudioMenu.checkingTitle(text: en), "Checking the ox-say service…")
        XCTAssertEqual(StudioMenu.checkingTitle(text: ru), "Проверяю службу ox-say…")
        let status = DaemonStatus(version: "v0.1.21", studioAvailable: true, studioReason: nil, studioReasonCode: nil)
        let running = job(.pausedOnBattery)
        let rows = StudioMenu.rows(service: .answered(status), installing: false, job: running, serviceWaiting: false,
                                   hasOutputFolder: true, text: ru)
        XCTAssertEqual(rows, [
            .item(title: "Новая озвучка из документа…", isOn: false, isEnabled: false, action: .newVoiceover),
            .item(title: "“Глава” — пауза — работа от батареи", isOn: false, isEnabled: false, action: nil),
            .item(title: "Остановить озвучку", isOn: false, isEnabled: true, action: .stopVoiceover),
            .item(title: "Продолжить работу от батареи", isOn: false, isEnabled: true, action: .continueOnBattery),
            .item(title: "Открыть папку с озвучками", isOn: false, isEnabled: true, action: .openVoiceoversFolder),
            .separator,
            .item(title: "Создать голос…", isOn: false, isEnabled: true, action: .createVoice),
        ])
        XCTAssertEqual(StudioMenu.rows(service: .unreachable, installing: false, job: nil, serviceWaiting: false, hasOutputFolder: false, text: ru),
                       [.item(title: "Студии нужна служба ox-say, а она не отвечает", isOn: false, isEnabled: false, action: nil)])
        XCTAssertEqual(StudioMenu.rows(service: .unknown, installing: false, job: nil, serviceWaiting: false, hasOutputFolder: false, text: ru),
                       [.item(title: "Проверяю службу ox-say…", isOn: false, isEnabled: false, action: nil)])
    }

    func testTheProgressRowsAndFinishAlertsReadRightInBothLanguages() {
        XCTAssertEqual(ProduceText.progressRow(job(.running), text: ru), "“Глава” — частей: 3 из 10")
        XCTAssertEqual(ProduceText.progressRow(job(.running, done: 0, total: 0), text: ru), "“Глава” — запускается…")
        XCTAssertEqual(ProduceText.progressRow(job(.running, title: ""), text: ru), "Озвучка — частей: 3 из 10")
        XCTAssertEqual(ProduceText.progressRow(job(.running, title: ""), text: en), "Voiceover — 3 of 10 parts")
        XCTAssertEqual(ProduceText.progressRow(job(.waitingForDictation), text: ru), "“Глава” — пауза — вы диктуете")
        XCTAssertEqual(ProduceText.progressRow(job(.done), text: ru), "“Глава” — готово")
        XCTAssertEqual(ProduceText.progressRow(job(.review, review: 1), text: ru), "“Глава” — готово — нужно прослушать 1 часть")
        XCTAssertEqual(ProduceText.progressRow(job(.review, review: 3), text: ru), "“Глава” — готово — нужно прослушать части (3)")
        XCTAssertEqual(ProduceText.progressRow(job(.failed), text: ru), "“Глава” — не получилось")
        XCTAssertEqual(ProduceText.progressRow(job(.cancelled), text: ru), "“Глава” — остановлена")
        XCTAssertEqual(ProduceText.progressRow(job(.interrupted), text: ru), "“Глава” — прервана")
        XCTAssertEqual(ProduceText.progressRow(job(.running), serviceWaiting: true, text: ru), "“Глава” — жду службу ox-say…")
        XCTAssertEqual(ProduceText.progressRow(job(.running), serviceWaiting: true, text: en), "“Глава” — waiting for the ox-say service…")
        let done = job(.done, wav: "/x/Ch.wav")
        XCTAssertEqual(ProduceText.finishAlert(done, text: ru)?.title, "Озвучка готова")
        XCTAssertEqual(ProduceText.finishAlert(done, text: ru)?.text, "Сохранено как Ch.wav.")
        XCTAssertEqual(ProduceText.finishAlert(job(.review, review: 2, wav: "/x/Ch.wav"), text: ru)?.text,
                       "Сохранено как Ch.wav. Нужно прослушать части (2). Эти части лежат в папке.")
        XCTAssertEqual(ProduceText.finishAlert(job(.done), text: ru)?.text, "Сохранено как файл озвучки.")
        XCTAssertEqual(ProduceText.finishAlert(job(.failed), text: ru)?.title, "Не удалось сделать озвучку")
        XCTAssertEqual(ProduceText.finishAlert(job(.failed), text: ru)?.text, "ox-say не смог её закончить.")
        XCTAssertEqual(ProduceText.finishAlert(job(.failed, error: "the disk is full"), text: ru)?.text, "the disk is full",
                       "the daemon's own reason stays as it sent it")
        XCTAssertEqual(ProduceText.finishAlert(job(.interrupted), text: ru)?.title, "Озвучка прервана")
        XCTAssertEqual(ProduceText.finishAlert(job(.interrupted), text: ru)?.text,
                       "ox-say остановился во время работы. Начните озвучку заново через «Новая озвучка из документа…».")
        XCTAssertEqual(ProduceText.finishAlert(job(.interrupted), text: en)?.text,
                       "ox-say stopped while it was working. Start it again with New Voiceover from Document.")
        XCTAssertEqual(ProduceFormat.short.title(text: ru), "Reels / Shorts (короткое)")
        XCTAssertEqual(ProduceFormat.long.title(text: ru), "YouTube (длинное)")
    }

    func testTheFlowAlertsReadRightInBothLanguages() {
        struct Boom: Error {}
        XCTAssertEqual(StudioDialogs.playFailed(text: en), UpdateDialog(title: "Couldn't play the voiceover",
            text: "The file could not be opened. It may have been moved.", buttons: ["OK"]))
        XCTAssertEqual(StudioDialogs.playFailed(text: ru), UpdateDialog(title: "Не удалось воспроизвести озвучку",
            text: "Не удалось открыть файл. Возможно, его переместили.", buttons: ["OK"]))
        XCTAssertEqual(StudioDialogs.serviceDown(text: en), UpdateDialog(title: "The ox-say service isn't answering",
            text: "Try again in a moment.", buttons: ["OK"]))
        XCTAssertEqual(StudioDialogs.serviceDown(text: ru), UpdateDialog(title: "Служба ox-say не отвечает",
            text: "Попробуйте ещё раз через минуту.", buttons: ["OK"]))
        XCTAssertEqual(StudioDialogs.startFailed(StudioError.refused(status: 400, message: "The script is empty."), text: en),
                       UpdateDialog(title: "Couldn't start the voiceover",
                                    text: "The script is empty. Your text is kept in the next window.", buttons: ["OK"]))
        XCTAssertEqual(StudioDialogs.startFailed(StudioError.timedOut, text: ru),
                       UpdateDialog(title: "Не удалось начать озвучку",
                                    text: "Служба ox-say слишком долго не отвечала. Ваш текст сохранён в следующем окне.", buttons: ["OK"]))
        XCTAssertEqual(StudioDialogs.stop(text: en), UpdateDialog(title: "Stop this voiceover?",
            text: "ox-say stops after the part it is working on. What is already made is not turned into a finished file.",
            buttons: ["Stop Voiceover", "Keep Going"]))
        XCTAssertEqual(StudioDialogs.stop(text: ru), UpdateDialog(title: "Остановить эту озвучку?",
            text: "ox-say остановится после той части, над которой работает. Итоговый файл из уже готовых частей не соберётся.",
            buttons: ["Остановить озвучку", "Продолжить"]))
        XCTAssertEqual(StudioDialogs.stopFailed(Boom(), text: en), UpdateDialog(title: "Couldn't stop the voiceover",
            text: "Something went wrong. Try again.", buttons: ["OK"]))
        XCTAssertEqual(StudioDialogs.stopFailed(Boom(), text: ru), UpdateDialog(title: "Не удалось остановить озвучку",
            text: "Что-то пошло не так. Попробуйте ещё раз.", buttons: ["OK"]))
        XCTAssertEqual(StudioDialogs.continueFailed(StudioError.daemonUnreachable, text: ru), UpdateDialog(
            title: "Не удалось продолжить озвучку", text: "Служба ox-say не запущена. Попробуйте перезагрузить Mac.", buttons: ["OK"]))
        XCTAssertEqual(StudioDialogs.continueFailed(StudioError.daemonUnreachable, text: en).title, "Couldn't continue the voiceover")
        XCTAssertEqual(StudioDialogs.readFailed(DocumentError.passwordProtected, text: ru), UpdateDialog(
            title: "Не удалось прочитать файл", text: "Этот PDF защищён паролем. Сохраните копию без пароля и откройте её.", buttons: ["OK"]))
        XCTAssertEqual(StudioDialogs.readFailed(Boom(), text: en), UpdateDialog(
            title: "Couldn't read that file", text: "The file could not be opened.", buttons: ["OK"]))
        XCTAssertEqual(StudioDialogs.nothingToRead(ReadScript(script: "", emptyReason: .noTextPDF), text: ru), UpdateDialog(
            title: "Нечего читать", text: "В этом PDF нет текста для чтения (возможно, это скан).", buttons: ["OK"]))
        XCTAssertEqual(StudioDialogs.nothingToRead(ReadScript(script: "", emptyReason: .noTextDocument), text: en).title, "Nothing to read")
        XCTAssertEqual(StudioDialogs.finished(job(.done, wav: "/x/Ch.wav"), text: ru)?.buttons, ["Показать в Finder", "Воспроизвести", "OK"])
        XCTAssertEqual(StudioDialogs.finished(job(.done, wav: "/x/Ch.wav"), text: en)?.buttons, ["Show in Finder", "Play", "OK"])
        XCTAssertEqual(StudioDialogs.finished(job(.failed), text: ru)?.buttons, ["OK"])
        XCTAssertNil(StudioDialogs.finished(job(.cancelled), text: ru), "a voiceover stopped on purpose earns no alert")
    }

    func testTheErrorsAreWordedInTheUsersLanguageAndKeepTheirEnglishForLogs() {
        let all: [StudioError] = [.daemonUnreachable, .timedOut, .badResponse, .refused(status: 500, message: "")]
        for error in all { XCTAssertEqual(error.message(text: en), error.description, "\(error): description is the English log text") }
        XCTAssertEqual(StudioError.timedOut.message(text: ru), "Служба ox-say слишком долго не отвечала.")
        XCTAssertEqual(StudioError.badResponse.message(text: ru), "Служба ox-say прислала ответ, который приложение не понимает.")
        XCTAssertEqual(StudioError.refused(status: 500, message: "").message(text: ru), "Служба ox-say ответила ошибкой (500).")
        XCTAssertEqual(StudioError.refused(status: 400, message: "Daemon's own words.").message(text: ru), "Daemon's own words.")
        let docs: [DocumentError] = [.unsupported("pages"), .unsupported("xyz"), .unreadable, .passwordProtected, .unknownEncoding]
        for error in docs { XCTAssertEqual(error.message(text: en), error.description, "\(error)") }
        XCTAssertEqual(DocumentError.unsupported("pages").message(text: ru),
                       "Файлы Pages нельзя читать напрямую. В Pages выберите «Файл» → «Экспортировать в» → Word или PDF, затем откройте этот файл.")
        XCTAssertEqual(DocumentError.unsupported("xyz").message(text: ru), "ox-say читает текстовые файлы, Markdown, Word, RTF, OpenDocument и PDF.")
        XCTAssertEqual(DocumentError.unreadable.message(text: ru), "Не удалось открыть файл. Возможно, он повреждён или не того типа, что указано в имени.")
        XCTAssertEqual(DocumentError.unknownEncoding.message(text: ru), "ox-say не смог определить кодировку символов в этом файле. Сохраните его как текст UTF-8 и откройте снова.")
        XCTAssertEqual(ReadScript(script: "", emptyReason: .cleanedAwayPDF).emptyMessage(text: ru), "После очистки в этом PDF не нашлось читаемого текста.")
        XCTAssertEqual(ReadScript(script: "", emptyReason: .cleanedAwayDocument).emptyMessage(text: ru), "После очистки в этом документе не нашлось читаемого текста.")
        XCTAssertEqual(ReadScript(script: "", emptyReason: .noTextDocument).emptyMessage(text: ru), "В этом документе нет текста для чтения.")
        XCTAssertEqual(ReadScript(script: "", emptyReason: .cleanedAwayPDF).emptyMessage(text: en), "ox-say could not find readable text in this PDF after cleaning it up.")
    }

    func testTheScriptLineAndVoiceMenuReadRightInBothLanguages() {
        XCTAssertEqual(ScriptLimit.statusLine(editorText: "", text: ru), "Читать пока нечего: текста нет.")
        XCTAssertEqual(ScriptLimit.statusLine(editorText: "Привет.", text: ru), "7 симв. · около 1 мин")
        XCTAssertEqual(ScriptLimit.statusLine(editorText: String(repeating: "я", count: 8340), text: ru), "8340 симв. · около 10 мин")
        XCTAssertEqual(ScriptLimit.statusLine(editorText: String(repeating: "я", count: ScriptLimit.maxCharacters + 7), text: ru),
                       "40007 симв. · превышает лимит в 40000 на 7 (это около 48 мин).")
        XCTAssertEqual(ScriptLimit.statusLine(editorText: String(repeating: "x", count: ScriptLimit.maxCharacters + 7), text: en),
                       "40007 characters · 7 over the limit of 40000 (about 48 minutes).")
        let rows = MenuSections.voiceRows(known: ["anna"], russian: nil, english: nil, text: ru)
        XCTAssertEqual(rows.first, .header("Русский"))
        XCTAssertTrue(rows.contains(.header("Английский")))
        XCTAssertTrue(rows.contains(.item(title: "Голос по умолчанию", isOn: true, isEnabled: true, action: .pickVoice(.russian, name: nil))))
        XCTAssertTrue(rows.contains(.item(title: "Случайный каждый раз", isOn: false, isEnabled: true, action: .pickVoice(.english, name: "default"))))
        XCTAssertTrue(MenuSections.voiceRows(known: nil, russian: nil, english: nil, text: ru)
            .contains(.item(title: "Загрузка…", isOn: false, isEnabled: false, action: nil)))
        let keys = MenuSections.shortcutRows(dictation: [], speak: [], text: ru)
        XCTAssertEqual(keys, [.header("Диктовка"), .separator, .header("Озвучить выделенное")])
        XCTAssertEqual(MenuSections.shortcutRows(dictation: [], speak: [], text: en), [.header("Dictation"), .separator, .header("Speak Selection")])
    }

    func testTheStatusPillNoticesAndShortcutRowsReadRightInBothLanguages() {
        XCTAssertEqual(SlowTranscription.pillText(seconds: 5, reason: nil, text: en), "Transcribing… 5s")
        XCTAssertEqual(SlowTranscription.pillText(seconds: 5, reason: "", text: en), "Transcribing… 5s")
        XCTAssertEqual(SlowTranscription.pillText(seconds: 5, reason: "the daemon did not answer", text: en), "Transcribing… 5s · the daemon did not answer")
        XCTAssertEqual(SlowTranscription.pillText(seconds: 12, reason: nil, text: ru), "Расшифровываю… 12 с")
        XCTAssertEqual(SlowTranscription.pillText(seconds: 12, reason: SlowTranscription.reason(sttServerState: "starting", text: ru), text: ru),
                       "Расшифровываю… 12 с · загружается модель распознавания речи")
        XCTAssertEqual(SlowTranscription.reason(sttServerState: "crashed", text: ru), "ox-say не запущена — медленнее")
        XCTAssertEqual(SlowTranscription.reason(sttServerState: "off", text: ru), "служба ox-say выключена")
        XCTAssertEqual(SlowTranscription.reason(sttServerState: "ready", text: ru), "расшифровывается длинная запись")
        XCTAssertEqual(SlowTranscription.reason(sttServerState: nil, text: ru), "служба ox-say не ответила")
        XCTAssertEqual(ClipboardReason.accessibility.message(text: en),
                       "Pasting needs the Accessibility permission — choose \"Allow pasting…\" in this app's menu. The text is on the clipboard.")
        XCTAssertEqual(ClipboardReason.accessibility.message(text: ru),
                       "Для вставки нужно разрешение универсального доступа — выберите «Разрешить вставку…» в меню приложения. Текст в буфере обмена.")
        XCTAssertEqual(ClipboardReason.secureInput.message(text: ru),
                       "Включён защищённый ввод (поле пароля или «Защищённый ввод с клавиатуры»), поэтому текст не вставлен. Он в буфере обмена.")
        XCTAssertEqual(ClipboardReason.focusMoved.message(text: ru),
                       "Вы переключились на другое приложение, пока шла расшифровка, поэтому текст не вставлен. Он в буфере обмена.")
        XCTAssertEqual(ClipboardReason.focusMoved.message(text: en),
                       "You switched apps while it was transcribing, so the text was not pasted. It is on the clipboard.")
        let ctrl = ShortcutMenu.Choice(title: "⌃Space", keyCode: 49, modifiers: 0x1000)
        let taken = [SystemShortcut(keyCode: 49, modifiers: 0x1000, enabled: true)]
        let plan = ShortcutMenu.plan(stored: nil, active: nil, choices: [ctrl], system: taken, text: ru)
        XCTAssertEqual(plan.items.first?.title, "⌃Space (системное сочетание macOS)")
        XCTAssertEqual(ShortcutMenu.plan(stored: nil, active: nil, choices: [ctrl], system: taken, text: en).items.first?.title, "⌃Space (a macOS shortcut)")
        XCTAssertEqual(en(.noticeSelectionNothing), "Nothing selected to speak.")
        XCTAssertEqual(ru(.noticeSelectionNothing), "Нечего озвучить: ничего не выделено.")
    }

    func testTheMenuNoticeAndPillKeysHaveTheirExactTexts() {
        let pairs: [(L10nKey, String, String)] = [
            (.menuAllowPasting, "Allow pasting… (Accessibility is off)", "Разрешить вставку… (универсальный доступ выключен)"),
            (.menuToggleMode, "Toggle Mode (press to start, press again to stop)", "Режим переключения (нажмите, чтобы начать, и ещё раз, чтобы закончить)"),
            (.menuStartAtLogin, "Start at Login", "Запускать при входе в систему"),
            (.menuMicrophoneAccess, "Microphone Access…", "Доступ к микрофону…"),
            (.menuAccessibilityAccess, "Accessibility Access…", "Универсальный доступ…"),
            (.menuVoice, "Voice", "Голос"), (.menuKeyboardShortcuts, "Keyboard Shortcuts", "Сочетания клавиш"),
            (.menuStudio, "Studio", "Студия"), (.menuSettings, "Settings", "Настройки"),
            (.menuAppAbout, "About OxSay", "О программе OxSay"), (.menuAppQuit, "Quit OxSay", "Завершить OxSay"),
            (.statusNoKey, "No dictation key", "Нет клавиши диктовки"),
            (.statusListening, "Listening… (esc cancels)", "Слушаю… (esc — отмена)"),
            (.statusTranscribing, "Transcribing… (esc cancels)", "Расшифровываю… (esc — отмена)"),
            (.pillTranscribing, "Transcribing…", "Расшифровываю…"), (.pillSpeaking, "Speaking…", "Читаю вслух…"),
            (.studioReadingPill, "Reading the document…", "Читаю документ…"),
            (.studioChooseTitle, "Choose the document to voice", "Выберите документ для озвучки"),
            (.studioChooseMessage, "Choose a text, Markdown, Word, PDF, RTF or OpenDocument file.", "Выберите текстовый файл, Markdown, Word, PDF, RTF или OpenDocument."),
            (.noticeSpeakAllMacOS, "Every speak key is a macOS shortcut on this Mac. Free one in System Settings → Keyboard → Keyboard Shortcuts.",
             "Все клавиши озвучки — системные сочетания macOS. Освободите одну в Системных настройках → Клавиатура → Сочетания клавиш."),
            (.noticeAccessibilityRefresh, "Could not refresh the Accessibility permission: remove OxSayDictation with − in System Settings → Privacy & Security → Accessibility, then add it again.",
             "Не удалось обновить разрешение универсального доступа: удалите OxSayDictation кнопкой − в Системных настройках → Конфиденциальность и безопасность → Универсальный доступ, затем добавьте снова."),
            (.reviewTitle, "New Voiceover", "Новая озвучка"), (.reviewStart, "Start", "Начать"), (.reviewKeepFirst, "Keep the First Part", "Оставить только начало"),
            (.reviewLabelTitle, "Title", "Название"), (.reviewLabelFormat, "Format", "Формат"),
            (.reviewLabelText, "Text — check it and fix anything before ox-say reads it", "Текст: проверьте его и поправьте всё нужное, прежде чем ox-say его прочитает"),
        ]
        for (key, e, r) in pairs {
            XCTAssertEqual(en(key), e, key.rawValue)
            XCTAssertEqual(ru(key), r, key.rawValue)
        }
        XCTAssertEqual(L10nKey.statusHold.text(popup: en), "Hold ⌃Space and speak")
        XCTAssertEqual(L10nKey.statusHold.text(popup: ru), "Удерживайте ⌃Space и говорите")
        XCTAssertEqual(L10nKey.statusPress.text(popup: en), "Press ⌃Space to start and stop")
        XCTAssertEqual(L10nKey.statusPress.text(popup: ru), "Нажмите ⌃Space, чтобы начать и закончить")
        XCTAssertEqual(String(format: en(.menuSpeakHintKey), "⌃⌥S"), "Speak: ⌃⌥S on a selection, or right-click → Services")
        XCTAssertEqual(String(format: ru(.menuSpeakHintKey), "⌃⌥S"), "Озвучка: ⌃⌥S на выделенном тексте или правый клик → Службы")
        XCTAssertEqual(en(.menuSpeakHintNone), "Speak: select text, then right-click → Services")
        XCTAssertEqual(ru(.menuSpeakHintNone), "Озвучка: выделите текст и нажмите правой кнопкой → Службы")
        XCTAssertEqual(String(format: en(.noticeSpeakTaken), "⌃⌥S"), "⌃⌥S is taken by another app, so speaking has no hotkey. Pick another one in this menu.")
        XCTAssertEqual(String(format: ru(.noticeSpeakTaken), "⌃⌥S"), "⌃⌥S занято другим приложением, поэтому у озвучки нет горячей клавиши. Выберите другую в этом меню.")
        XCTAssertEqual(String(format: en(.noticeSpeakMoved), "⌃⌥S", "⌃⌥R"), "⌃⌥S is a macOS shortcut on this Mac, so speaking uses ⌃⌥R.")
        XCTAssertEqual(String(format: ru(.noticeSpeakMoved), "⌃⌥S", "⌃⌥R"), "⌃⌥S — системное сочетание macOS, поэтому озвучка работает на ⌃⌥R.")
        XCTAssertEqual(String(format: en(.noticeLoginFailed), "denied"), "Start at login: denied")
        XCTAssertEqual(String(format: ru(.noticeLoginFailed), "denied"), "Запуск при входе в систему: denied")
        XCTAssertEqual(en(.recordingEndedMicChanged), "The microphone changed while recording.")
        XCTAssertEqual(ru(.recordingEndedMicChanged), "Микрофон сменился во время записи.")
        XCTAssertEqual(String(format: en(.recordingEndedCap), "600"), "Recordings stop after 600 seconds.")
        XCTAssertEqual(String(format: ru(.recordingEndedCap), "600"), "Запись останавливается через 600 с.")
        XCTAssertEqual(String(format: en(.reviewStartTip), "⌘Return"), "Start the voiceover (⌘Return)")
        XCTAssertEqual(String(format: ru(.reviewStartTip), "⌘Return"), "Начать озвучку (⌘Return)")
    }

    /// The dictation controller words a failed start through its injected localizer. Mutation: DictationController,
    /// `onError?(String(format: localize(.noticeRecordFailed), …))` back to a literal -> RED.
    func testAFailedStartIsReportedInTheUsersLanguage() {
        XCTAssertEqual(String(format: en(.noticeRecordFailed), "no permission"), "Could not start recording: no permission")
        XCTAssertEqual(String(format: ru(.noticeRecordFailed), "no permission"), "Не удалось начать запись: no permission")
    }

    /// The retired English literals must not come back at their call sites.
    /// Mutation: StudioController.stopVoiceover, `show(StudioDialogs.stop())` back to
    /// `host.alert("Stop this voiceover?", …, ["Stop Voiceover", "Keep Going"])` -> RED.
    func testNoRetiredEnglishLiteralRemainsAtTheCallSites() throws {
        let retired: [String: [String]] = [
            "OxSayDictation/StudioController.swift": ["Couldn't play", "isn't answering", "Couldn't start", "Reading the document", "Nothing to read",
                "Couldn't read that file", "Stop this voiceover", "Stop Voiceover", "Keep Going", "Couldn't stop", "Couldn't continue",
                "[\"Show in Finder\"", "\"Play\"", "[\"OK\"]", "Something went wrong", "static func plain"],
            "OxSayDictation/StudioForms.swift": ["Choose the document to voice", "Choose a text, Markdown"],
            "OxSayDictation/ReviewSheet.swift": ["\"New Voiceover\"", "\"Start\"", "title: \"Keep the First Part\"", "\"Cancel\"", "\"Title\"", "\"Format\"",
                "\"Voice\"", "Text — check it", "Default voice", "Start the voiceover ("],
            "OxSayDictation/MeetingController.swift": ["addButton(withTitle: \"OK\")", "addButton(withTitle: \"Cancel\")", "host.notify(\"\\(error)\")"],
            "OxSayDictation/Overlay.swift": ["labelWithString: \"Transcribing…\"", "setWorkingText(\"Transcribing…\")"],
            "OxSayDictation/AppDelegate.swift": ["Allow pasting… (Accessibility", "Toggle Mode (press", "\"Start at Login\"", "Every speak key is", "is taken by another app",
                "so speaking uses", "\"Speak: ", "\"Voice\"", "\"Keyboard Shortcuts\"", "\"Studio\"", "\"Settings\"", "\"About OxSay\"", "\"Quit OxSay\"",
                "\"Hold \\(", "\"Press \\(", "\"No dictation key\"", "\"Listening…", "\"Transcribing…", "setWorkingText(\"Speaking…\")", "Nothing selected to speak.\"",
                "\"Start at login: ", "Could not refresh the Accessibility", "Microphone Access…\"", "Accessibility Access…\""],
            "OxSayDictation/PasteOutput.swift": ["reason.message)"],
            "OxSayDictation/MicRecorder.swift": ["end(\"The microphone changed", "end(\"Recordings stop after"],
            "DictationCore/StudioMenu.swift": ["= \"New Voiceover", "= \"Stop Voiceover", "= \"Continue on Battery", "= \"Open Voiceovers", "= \"Studio needs", "= \"Checking the"],
            "DictationCore/ProduceModels.swift": ["\"Voiceover\"", "\"paused —", "\"ready", "return \"failed\"", "return \"stopped\"", "return \"interrupted\"", "starting…\"",
                "of \\(job.partsTotal) parts", "need a listen\"", "\"Voiceover ready\"", "The voiceover failed", "could not finish it", "was interrupted",
                "Reels / Shorts (short)", "YouTube (long)", "waiting for the ox-say service"],
            "DictationCore/StudioClient.swift": ["fallback: \"The ox-say service answered"],
            "DictationCore/DocumentReader.swift": ["emptyMessage: document.emptyMessage"],
            "DictationCore/ScriptLimit.swift": ["There is no text to read yet.\"", "characters · "],
            "DictationCore/MenuSections.swift": ["= \"Default voice\"", "= \"Random each time\"", "= \"Loading…\"", "= \"Dictation\"", "= \"Speak Selection\"", "return \"Russian\"", "return \"English\""],
            "DictationCore/SlowTranscription.swift": ["return \"loading the speech model\"", "return \"the speech server is off\"", "return \"the daemon did not answer\""],
            "DictationCore/OutputPolicy.swift": ["Pasting needs the Accessibility", "Secure input is on", "You switched apps"],
            "DictationCore/DictationController.swift": ["onError?(\"Could not start recording"],
            "DictationCore/ShortcutMenu.swift": ["\\(choice.title) (a macOS shortcut)"],
        ]
        for (file, literals) in retired {
            let text = try source(file)
            for literal in literals { XCTAssertFalse(text.contains(literal), "\(file) still has \(literal)") }
        }
        let app = try source("OxSayDictation/AppDelegate.swift")
        for pin in ["L10nKey.menuAllowPasting.text", "L10nKey.menuToggleMode.text", "L10nKey.menuStartAtLogin.text", "L10nKey.noticeSpeakAllMacOS.text",
                    "L10nKey.noticeSpeakTaken.text(key.title)", "L10nKey.noticeSpeakMoved.text(taken.title, key.title)", "L10nKey.menuStudio.text",
                    "L10nKey.menuSettings.text", "L10nKey.menuAppAbout.text", "L10nKey.menuAppQuit.text", "L10nKey.statusListening.text",
                    "SlowTranscription.pillText(seconds: seconds, reason: slowReason)", "L10nKey.pillSpeaking.text",
                    "L10nKey.noticeLoginFailed.text(error.localizedDescription)", "let failure = L10nKey.noticeAccessibilityRefresh.text"] {
            XCTAssertTrue(app.contains(pin), "AppDelegate.swift lost `\(pin)`")
        }
        let studio = try source("OxSayDictation/StudioController.swift")
        for pin in ["show(StudioDialogs.stop())", "StudioDialogs.finished(finished)", "show(StudioDialogs.playFailed())", "show(StudioDialogs.serviceDown())",
                    "show(StudioDialogs.startFailed(error))", "show(StudioDialogs.nothingToRead(read))", "show(StudioDialogs.readFailed(error))",
                    "StudioDialogs.stopFailed(error)", "StudioDialogs.continueFailed(error)"] {
            XCTAssertTrue(studio.contains(pin), "StudioController.swift lost `\(pin)`")
        }
    }
}

private extension L10nKey {
    /// `statusHold` / `statusPress` with ⌃Space filled in, through a given localizer.
    func text(popup localizer: (L10nKey) -> String) -> String { String(format: localizer(self), "⌃Space") }
}
