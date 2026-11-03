import XCTest
@testable import DictationCore

/// SpeakText is the Озвучка section's localization seam: each formatter takes
/// the inputs its English Studio counterpart takes plus a key lookup — fed
/// here from the shipped Localizable.strings files themselves, so the
/// asserted Russian is the text the window really draws.
final class SpeakTextTests: XCTestCase {
    private lazy var ru = ShippedStrings.localizer("ru")
    private lazy var en = ShippedStrings.localizer("en")

    private func job(_ status: ProduceStatus, title: String = "Ролик", total: Int = 10, done: Int = 3,
                     review: Int = 0, error: String? = nil, wav: String? = nil) -> ProduceJob {
        ProduceJob(id: "j", title: title, status: status, partsTotal: total, partsDone: done,
                   partsToReview: review, error: error, outputPath: wav)
    }

    // MARK: the script status line (ScriptLimit.statusLine's inputs)

    func testTheStatusLineReadsRussian() {
        XCTAssertEqual(SpeakText.statusLine(editorText: "", ru), "Пока нет текста для чтения.")
        XCTAssertEqual(SpeakText.statusLine(editorText: "Hello.", ru), "Символов: 6 · примерно 1 мин.")
        XCTAssertEqual(SpeakText.statusLine(editorText: String(repeating: "я", count: 8340), ru),
                       "Символов: 8340 · примерно 10 мин.")
        let over = String(repeating: "я", count: ScriptLimit.maxCharacters + 7)
        XCTAssertEqual(SpeakText.statusLine(editorText: over, ru),
                       "Символов: 40007 · на 7 сверх лимита 40000 (около 48 мин.).")
    }

    func testTheEnglishStatusLineKeepsTheStudioShape() {
        XCTAssertEqual(SpeakText.statusLine(editorText: "Hello.", en), "6 characters · about 1 minute")
        XCTAssertEqual(SpeakText.statusLine(editorText: String(repeating: "я", count: 8340), en),
                       "8340 characters · about 10 minutes")
    }

    // MARK: the progress row (ProduceText.progressRow's inputs)

    func testTheProgressRowReadsRussian() {
        XCTAssertEqual(SpeakText.progressRow(job(.running), serviceWaiting: false, ru),
                       "Озвучка «Ролик» — Готово: 3 из 10")
        XCTAssertEqual(SpeakText.progressRow(job(.running), serviceWaiting: true, ru),
                       "Озвучка «Ролик» — жду ответа сервиса ox-say…")
        XCTAssertEqual(SpeakText.progressRow(job(.pausedOnBattery), serviceWaiting: false, ru),
                       "Озвучка «Ролик» — пауза — питание от батареи")
        XCTAssertEqual(SpeakText.progressRow(job(.waitingForDictation), serviceWaiting: false, ru),
                       "Озвучка «Ролик» — пауза — идёт диктовка")
        XCTAssertEqual(SpeakText.progressRow(job(.running, total: 0, done: 0), serviceWaiting: false, ru),
                       "Озвучка «Ролик» — запускаю…")
        XCTAssertEqual(SpeakText.progressRow(job(.running, title: ""), serviceWaiting: false, ru),
                       "Озвучка — Готово: 3 из 10")
    }

    /// Every status the daemon reports maps to its own detail, in both
    /// languages — a part count names no plural, so 1 or 21 parts reads the
    /// same way. Mutations: .failed reading .speakProgressStopped (the old
    /// SpeakText.swift:41) -> RED; ru speak.progress_parts back to
    /// "%lld из %lld частей" -> RED.
    func testEveryStatusHasItsOwnProgressDetail() {
        let rows: [(ProduceStatus, Int, String, String)] = [
            (.running, 0, "Готово: 3 из 10", "3 of 10 done"),
            (.pausedOnBattery, 0, "пауза — питание от батареи", "paused — on battery power"),
            (.waitingForDictation, 0, "пауза — идёт диктовка", "paused — you are dictating"),
            (.review, 1, "готово — 1 часть нужно прослушать", "ready — 1 part needs a listen"),
            (.review, 3, "готово — частей нужно прослушать: 3", "ready — 3 parts need a listen"),
            (.done, 0, "готово", "ready"),
            (.failed, 0, "не удалось", "failed"),
            (.cancelled, 0, "остановлено", "stopped"),
            (.interrupted, 0, "прервано", "interrupted"),
            (.unknown("hibernating"), 0, "Готово: 3 из 10", "3 of 10 done"),
        ]
        for (status, review, wantRu, wantEn) in rows {
            let j = job(status, review: review)
            XCTAssertEqual(SpeakText.progressRow(j, serviceWaiting: false, ru),
                           "Озвучка «Ролик» — \(wantRu)", "\(status) in ru")
            XCTAssertEqual(SpeakText.progressRow(j, serviceWaiting: false, en),
                           "Voiceover “Ролик” — \(wantEn)", "\(status) in en")
        }
        XCTAssertEqual(SpeakText.progressRow(job(.failed), serviceWaiting: true, ru),
                       "Озвучка «Ролик» — жду ответа сервиса ox-say…",
                       "serviceWaiting overrides the detail, whatever the status")
        XCTAssertEqual(SpeakText.progressRow(job(.running, total: 0, done: 0), serviceWaiting: false, en),
                       "Voiceover “Ролик” — starting…")
    }

    // MARK: the finish line (ProduceText.finishAlert's inputs)

    func testTheFinishTextReadsRussian() {
        XCTAssertEqual(SpeakText.finishText(job(.done, wav: "/x/ролик.wav"), ru), "Сохранено как ролик.wav.")
        XCTAssertEqual(SpeakText.finishText(job(.review, review: 1, wav: "/x/р.wav"), ru),
                       "Сохранено как р.wav. Одна часть на прослушку — она в папке.")
        XCTAssertEqual(SpeakText.finishText(job(.review, review: 3, wav: "/x/р.wav"), ru),
                       "Сохранено как р.wav. Частей на прослушку: 3 — они в папке.")
        XCTAssertNil(SpeakText.finishText(job(.cancelled), ru), "stopped on purpose: nothing to announce")
    }

    /// The daemon's own error text stays verbatim behind a localized lead-in;
    /// the interrupted line names a button the section actually has.
    func testTheFinishTextKeepsTheDaemonsWordsAndTheCreateButton() {
        XCTAssertEqual(SpeakText.finishText(job(.failed, error: "disk full"), ru),
                       "Сервис ox-say ответил: disk full")
        XCTAssertEqual(SpeakText.finishText(job(.failed), ru), "ox-say не смог закончить её.")
        let interrupted = SpeakText.finishText(job(.interrupted), ru)
        XCTAssertEqual(interrupted?.contains("«Озвучить»"), true)
        XCTAssertEqual(interrupted?.contains("New Voiceover"), false,
                       "the section has no such menu item")
    }

    /// The whole `finishText` switch in both languages: nil while the job
    /// still runs or was stopped on purpose.
    func testEveryEndedStatusHasItsFinishLine() {
        XCTAssertNil(SpeakText.finishText(job(.running), ru))
        XCTAssertNil(SpeakText.finishText(job(.running), en))
        XCTAssertNil(SpeakText.finishText(job(.waitingForDictation), ru))
        XCTAssertNil(SpeakText.finishText(job(.pausedOnBattery), en))
        XCTAssertNil(SpeakText.finishText(job(.cancelled), ru))
        XCTAssertNil(SpeakText.finishText(job(.cancelled), en))
        XCTAssertNil(SpeakText.finishText(job(.unknown("hibernating")), ru),
                     "a status added later is still working, not an ending")
        XCTAssertEqual(SpeakText.finishText(job(.done, wav: "/x/r.wav"), en), "Saved as r.wav.")
        XCTAssertEqual(SpeakText.finishText(job(.done), en), "Saved as Voiceover.")
        XCTAssertEqual(SpeakText.finishText(job(.review, review: 1, wav: "/x/r.wav"), en),
                       "Saved as r.wav. 1 part needs a listen — it is in the folder.")
        XCTAssertEqual(SpeakText.finishText(job(.review, review: 3, wav: "/x/r.wav"), en),
                       "Saved as r.wav. 3 parts need a listen — they are in the folder.")
        XCTAssertEqual(SpeakText.finishText(job(.interrupted), ru),
                       "ox-say остановился во время работы. Запустите её снова кнопкой «Озвучить».")
        XCTAssertEqual(SpeakText.finishText(job(.interrupted), en),
                       "ox-say stopped while it was working. Start it again with Create Voiceover.")
    }

    /// A done or review job still carrying the daemon's error is not a saved
    /// result: a loudness-only re-assembly keeps the old status and reports
    /// why it failed (internal/daemon/produce.go `outcome`). The person must
    /// read that the change did not happen — never "Saved".
    /// Mutation: finishText without the `job.error` check on .done -> RED.
    func testAFailedLoudnessDeliveryNeverReadsAsSaved() {
        XCTAssertEqual(SpeakText.finishText(job(.done, error: "the file is locked", wav: "/x/р.wav"), ru),
                       "Сервис ox-say ответил: the file is locked")
        XCTAssertEqual(SpeakText.finishText(job(.done, error: "the file is locked", wav: "/x/р.wav"), en),
                       "The ox-say service answered: the file is locked")
        XCTAssertEqual(SpeakText.finishText(job(.review, review: 2, error: "the file is locked", wav: "/x/р.wav"), ru),
                       "Сервис ox-say ответил: the file is locked")
        XCTAssertEqual(SpeakText.finishText(job(.done, error: "", wav: "/x/р.wav"), ru),
                       "ox-say не смог закончить её.", "an empty daemon error is the plain sentence, not Saved")
    }

    /// A failed job's line is the daemon's reason in plain words behind the
    /// lead-in; a jargon-only or empty reason is the plain sentence, never
    /// terminal-speak. Mutation: .failed without PlainWords.clean -> RED.
    func testAFailedJobReadsItsReasonInPlainWords() {
        XCTAssertEqual(SpeakText.finishText(job(.failed, error: "the disk is full"), en),
                       "The ox-say service answered: the disk is full")
        XCTAssertEqual(SpeakText.finishText(job(.failed, error: "rerun with OX_SAY_DEBUG=1."), ru),
                       "ox-say не смог закончить её.", "a jargon-only reason never shows")
        XCTAssertEqual(SpeakText.finishText(job(.failed, error: "rerun with OX_SAY_DEBUG=1."), en),
                       "ox-say could not finish it.")
        XCTAssertEqual(SpeakText.finishText(job(.failed, error: "it stopped early. rerun with OX_SAY_DEBUG=1."), en),
                       "The ox-say service answered: it stopped early.",
                       "the plain words stay, the jargon sentence goes")
    }

    // MARK: the notice line (StudioError's cases) and the can't-run fallback

    func testTheNoticeReadsRussian() {
        XCTAssertEqual(SpeakText.notice(StudioError.daemonUnreachable, ru),
                       "Сервис ox-say не запущен. Попробуйте перезагрузить Mac.")
        XCTAssertEqual(SpeakText.notice(StudioError.timedOut, ru), "Сервис ox-say не ответил вовремя.")
        XCTAssertEqual(SpeakText.notice(StudioError.badResponse, ru),
                       "Сервис ox-say прислал ответ, который приложение не понимает.")
        XCTAssertEqual(SpeakText.notice(StudioError.refused(status: 409, message: "another voiceover is being produced"), ru),
                       "Сервис ox-say ответил: another voiceover is being produced")
        XCTAssertEqual(SpeakText.notice(CocoaError(.fileNoSuchFile), ru), "Что-то пошло не так. Попробуйте ещё раз.")
    }

    /// StudioClient.refusal can carry an empty message (a body with no
    /// "message", or all jargon): the notice must not end on a bare lead-in —
    /// the status sentence reads instead, exactly as StudioError.message
    /// words it. Mutation: .refused without the empty-message branch -> RED.
    func testAnEmptyRefusalReadsTheStatusSentence() {
        XCTAssertEqual(SpeakText.notice(StudioError.refused(status: 409, message: ""), ru),
                       "Служба ox-say ответила ошибкой (409).")
        XCTAssertEqual(SpeakText.notice(StudioError.refused(status: 503, message: ""), en),
                       "The ox-say service answered with an error (503).")
    }

    /// The fallback is localized; the daemon's own reason passes through,
    /// cleaned, exactly like the menu's unavailableText.
    func testTheUnavailableReasonReadsRussian() {
        XCTAssertEqual(SpeakText.unavailableText(reason: nil, ru), "На этом Mac студийный голос не работает.")
        XCTAssertEqual(SpeakText.unavailableText(reason: "Only Apple Silicon can run it.", ru),
                       "Only Apple Silicon can run it.")
        XCTAssertEqual(SpeakText.unavailableText(reason: "Reinstall with OX_SAY_WITH_VOXCPM2=1.", ru),
                       "На этом Mac студийный голос не работает.", "a jargon-only reason falls back")
    }

    // MARK: the document errors and the empty-document message

    func testTheDocumentErrorsReadRussian() {
        XCTAssertEqual(SpeakText.documentError(DocumentError.passwordProtected, ru),
                       "Этот PDF защищён паролем. Сохраните копию без пароля и откройте её.")
        XCTAssertEqual(SpeakText.documentError(DocumentError.unsupported("pages"), ru),
                       "Файлы Pages не читаются напрямую. В Pages выберите «Файл → Экспорт в → Word или PDF» и откройте полученный файл.")
        XCTAssertEqual(SpeakText.documentError(DocumentError.unsupported("xyz"), ru),
                       "ox-say читает текстовые файлы, Markdown, Word, RTF, OpenDocument и PDF.")
        XCTAssertEqual(SpeakText.documentError(DocumentError.unreadable, ru),
                       "Файл не открывается. Возможно, он повреждён, или его формат не совпадает с расширением.")
        XCTAssertEqual(SpeakText.documentError(DocumentError.unknownEncoding, ru),
                       "ox-say не определил, в какой кодировке записан файл. Сохраните его как текст в UTF-8 и откройте снова.")
        XCTAssertEqual(SpeakText.documentError(CocoaError(.fileReadCorruptFile), ru), "Файл не удалось открыть.")
    }

    func testTheEmptyDocumentMessageReadsRussian() {
        XCTAssertEqual(SpeakText.emptyMessage(of: ReadDocument(pages: [""], source: .pdf), ru),
                       "В этом PDF нет текста для чтения (возможно, это скан).")
        XCTAssertEqual(SpeakText.emptyMessage(of: ReadDocument(pages: ["текст"], source: .pdf), ru),
                       "ox-say не нашёл читаемый текст в этом PDF даже после очистки.")
        XCTAssertEqual(SpeakText.emptyMessage(of: ReadDocument(pages: ["", "  \n"], source: .text), ru),
                       "В этом документе нет текста для чтения.")
        XCTAssertEqual(SpeakText.emptyMessage(of: ReadDocument(pages: ["текст"], source: .text), ru),
                       "ox-say не нашёл читаемый текст в этом документе даже после очистки.")
    }
}
