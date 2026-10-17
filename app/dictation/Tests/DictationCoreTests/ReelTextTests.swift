import XCTest
@testable import DictationCore

/// ReelText is the reel window's localization seam: each formatter takes the
/// inputs its English Studio counterpart takes plus a key lookup — fed here
/// from the shipped Localizable.strings files themselves, so the asserted
/// Russian is the text the window really draws.
final class ReelTextTests: XCTestCase {
    /// …/app/dictation/Tests/DictationCoreTests/<this file> → the package root.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The "key" = "value"; pairs of a Localizable.strings file as a lookup table.
    private func table(_ locale: String) -> [String: String] {
        let url = packageRoot.appendingPathComponent("Resources/\(locale).lproj/Localizable.strings")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let pattern = try! NSRegularExpression(pattern: #"^"([A-Za-z0-9._]+)"\s*=\s*"(.*)"\s*;"#)
        var table: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            guard let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            table[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        return table
    }

    private func tr(_ table: [String: String]) -> (L10nKey) -> String {
        { table[$0.rawValue] ?? $0.rawValue }
    }

    private lazy var ru = tr(table("ru"))
    private lazy var en = tr(table("en"))

    private func job(_ status: ProduceStatus, title: String = "Ролик", total: Int = 10, done: Int = 3,
                     review: Int = 0, error: String? = nil, wav: String? = nil) -> ProduceJob {
        ProduceJob(id: "j", title: title, status: status, partsTotal: total, partsDone: done,
                   partsToReview: review, error: error, outputPath: wav)
    }

    // MARK: the script status line (ScriptLimit.statusLine's inputs)

    func testTheStatusLineReadsRussian() {
        XCTAssertEqual(ReelText.statusLine(editorText: "", ru), "Пока нет текста для чтения.")
        XCTAssertEqual(ReelText.statusLine(editorText: "Hello.", ru), "Символов: 6 · примерно 1 мин.")
        XCTAssertEqual(ReelText.statusLine(editorText: String(repeating: "я", count: 8340), ru),
                       "Символов: 8340 · примерно 10 мин.")
        let over = String(repeating: "я", count: ScriptLimit.maxCharacters + 7)
        XCTAssertEqual(ReelText.statusLine(editorText: over, ru),
                       "Символов: 40007 · на 7 сверх лимита 40000 (около 48 мин.).")
    }

    func testTheEnglishStatusLineKeepsTheStudioShape() {
        XCTAssertEqual(ReelText.statusLine(editorText: "Hello.", en), "6 characters · about 1 minute")
        XCTAssertEqual(ReelText.statusLine(editorText: String(repeating: "я", count: 8340), en),
                       "8340 characters · about 10 minutes")
    }

    // MARK: the progress row (ProduceText.progressRow's inputs)

    func testTheProgressRowReadsRussian() {
        XCTAssertEqual(ReelText.progressRow(job(.running), serviceWaiting: false, ru),
                       "«Ролик» — 3 из 10 частей")
        XCTAssertEqual(ReelText.progressRow(job(.running), serviceWaiting: true, ru),
                       "«Ролик» — жду ответа сервиса ox-say…")
        XCTAssertEqual(ReelText.progressRow(job(.pausedOnBattery), serviceWaiting: false, ru),
                       "«Ролик» — пауза — питание от батареи")
        XCTAssertEqual(ReelText.progressRow(job(.waitingForDictation), serviceWaiting: false, ru),
                       "«Ролик» — пауза — идёт диктовка")
        XCTAssertEqual(ReelText.progressRow(job(.running, total: 0, done: 0), serviceWaiting: false, ru),
                       "«Ролик» — запускаю…")
        XCTAssertEqual(ReelText.progressRow(job(.running, title: ""), serviceWaiting: false, ru),
                       "Озвучка — 3 из 10 частей")
    }

    // MARK: the finish line (ProduceText.finishAlert's inputs)

    func testTheFinishTextReadsRussian() {
        XCTAssertEqual(ReelText.finishText(job(.done, wav: "/x/ролик.wav"), ru), "Сохранено как ролик.wav.")
        XCTAssertEqual(ReelText.finishText(job(.review, review: 1, wav: "/x/р.wav"), ru),
                       "Сохранено как р.wav. Одна часть на прослушку — она в папке.")
        XCTAssertEqual(ReelText.finishText(job(.review, review: 3, wav: "/x/р.wav"), ru),
                       "Сохранено как р.wav. Частей на прослушку: 3 — они в папке.")
        XCTAssertNil(ReelText.finishText(job(.cancelled), ru), "stopped on purpose: nothing to announce")
    }

    /// The daemon's own error text stays verbatim behind a localized lead-in;
    /// the interrupted line names a button the reel window actually has.
    func testTheFinishTextKeepsTheDaemonsWordsAndTheReelsButton() {
        XCTAssertEqual(ReelText.finishText(job(.failed, error: "disk full"), ru),
                       "Сервис ox-say ответил: disk full")
        XCTAssertEqual(ReelText.finishText(job(.failed), ru), "ox-say не смог закончить её.")
        let interrupted = ReelText.finishText(job(.interrupted), ru)
        XCTAssertEqual(interrupted?.contains("«Озвучить»"), true)
        XCTAssertEqual(interrupted?.contains("New Voiceover"), false,
                       "the reel window has no such menu item")
    }

    // MARK: the notice line (StudioError's cases) and the can't-run fallback

    func testTheNoticeReadsRussian() {
        XCTAssertEqual(ReelText.notice(StudioError.daemonUnreachable, ru),
                       "Сервис ox-say не запущен. Попробуйте перезагрузить Mac.")
        XCTAssertEqual(ReelText.notice(StudioError.timedOut, ru), "Сервис ox-say не ответил вовремя.")
        XCTAssertEqual(ReelText.notice(StudioError.badResponse, ru),
                       "Сервис ox-say прислал ответ, который приложение не понимает.")
        XCTAssertEqual(ReelText.notice(StudioError.refused(status: 409, message: "another voiceover is being produced"), ru),
                       "Сервис ox-say ответил: another voiceover is being produced")
        XCTAssertEqual(ReelText.notice(CocoaError(.fileNoSuchFile), ru), "Что-то пошло не так. Попробуйте ещё раз.")
    }

    /// The fallback is localized; the daemon's own reason passes through,
    /// cleaned, exactly like the menu's unavailableText.
    func testTheUnavailableReasonReadsRussian() {
        XCTAssertEqual(ReelText.unavailableText(reason: nil, ru), "На этом Mac студийный голос не работает.")
        XCTAssertEqual(ReelText.unavailableText(reason: "Only Apple Silicon can run it.", ru),
                       "Only Apple Silicon can run it.")
        XCTAssertEqual(ReelText.unavailableText(reason: "Reinstall with OX_SAY_WITH_VOXCPM2=1.", ru),
                       "На этом Mac студийный голос не работает.", "a jargon-only reason falls back")
    }

    // MARK: the document errors and the empty-document message

    func testTheDocumentErrorsReadRussian() {
        XCTAssertEqual(ReelText.documentError(DocumentError.passwordProtected, ru),
                       "Этот PDF защищён паролем. Сохраните копию без пароля и откройте её.")
        XCTAssertEqual(ReelText.documentError(DocumentError.unsupported("pages"), ru),
                       "Файлы Pages не читаются напрямую. В Pages выберите «Файл → Экспорт в → Word или PDF» и откройте полученный файл.")
        XCTAssertEqual(ReelText.documentError(DocumentError.unsupported("xyz"), ru),
                       "ox-say читает текстовые файлы, Markdown, Word, RTF, OpenDocument и PDF.")
        XCTAssertEqual(ReelText.documentError(DocumentError.unreadable, ru),
                       "Файл не открывается. Возможно, он повреждён, или его формат не совпадает с расширением.")
        XCTAssertEqual(ReelText.documentError(DocumentError.unknownEncoding, ru),
                       "ox-say не определил, в какой кодировке записан файл. Сохраните его как текст в UTF-8 и откройте снова.")
        XCTAssertEqual(ReelText.documentError(CocoaError(.fileReadCorruptFile), ru), "Файл не удалось открыть.")
    }

    func testTheEmptyDocumentMessageReadsRussian() {
        XCTAssertEqual(ReelText.emptyMessage(of: ReadDocument(pages: [""], source: .pdf), ru),
                       "В этом PDF нет текста для чтения (возможно, это скан).")
        XCTAssertEqual(ReelText.emptyMessage(of: ReadDocument(pages: ["текст"], source: .pdf), ru),
                       "ox-say не нашёл читаемый текст в этом PDF даже после очистки.")
        XCTAssertEqual(ReelText.emptyMessage(of: ReadDocument(pages: ["", "  \n"], source: .text), ru),
                       "В этом документе нет текста для чтения.")
        XCTAssertEqual(ReelText.emptyMessage(of: ReadDocument(pages: ["текст"], source: .text), ru),
                       "ox-say не нашёл читаемый текст в этом документе даже после очистки.")
    }
}
