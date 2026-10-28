import Foundation
import XCTest
@testable import DictationCore

/// A Russian user sees no English in the update, install and Create a Voice dialogs, pills and menu rows.
final class UpdateDesignL10nTests: XCTestCase {
    private let en = ShippedStrings.localizer("en")
    private let ru = ShippedStrings.localizer("ru")
    private var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }
    private func source(_ path: String) throws -> String { try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8) }

    func testTheBusyRepairAndStudioDialogsReadRightInBothLanguages() {
        XCTAssertEqual(UpdateDialogs.busy(text: en), UpdateDialog(title: "An update is already being installed.",
            text: "Wait for it to finish; ox-say restarts when it is done.", buttons: ["OK"]))
        XCTAssertEqual(UpdateDialogs.busy(text: ru), UpdateDialog(title: "Обновление уже устанавливается.",
            text: "Дождитесь окончания: ox-say перезапустится сам.", buttons: ["OK"]))
        XCTAssertEqual(UpdateDialogs.repair(target: "0.1.21", text: ru), UpdateDialog(title: "Починить ox-say?",
            text: "Приложение и служба ox-say работают на разных версиях. Будет заново установлена v0.1.21, она уже есть на диске; пока ox-say перезапускается, диктовка приостановится.",
            buttons: ["Починить", "Отмена"]))
        XCTAssertEqual(UpdateDialogs.repair(target: "0.1.21", text: en).buttons, ["Repair", "Cancel"])
        XCTAssertEqual(UpdateDialogs.repair(target: "0.1.21", text: en).text,
                       "The app and the ox-say service disagree on the version. This reinstalls v0.1.21, the version already on disk; dictation pauses while ox-say restarts.")
        XCTAssertEqual(UpdateDialogs.studioVoice(text: en), UpdateDialog(title: "Install the studio voice?",
            text: "Downloads the studio voice model once, about 3 GB. Dictation pauses for a few seconds while ox-say restarts.",
            buttons: ["Install", "Cancel"]))
        XCTAssertEqual(UpdateDialogs.studioVoice(text: ru), UpdateDialog(title: "Установить студийный голос?",
            text: "Модель студийного голоса скачивается один раз, около 3 ГБ. На несколько секунд, пока ox-say перезапускается, диктовка приостановится.",
            buttons: ["Установить", "Отмена"]))
    }

    func testTheCheckForUpdatesAnswersReadRightInBothLanguages() {
        XCTAssertEqual(UpdateDialogs.prompt(.upToDate(version: "0.1.21"), text: en),
                       UpdateDialog(title: "You're up to date", text: "ox-say v0.1.21 is the newest version.", buttons: ["OK"]))
        XCTAssertEqual(UpdateDialogs.prompt(.upToDate(version: "0.1.21"), text: ru),
                       UpdateDialog(title: "У вас последняя версия", text: "ox-say v0.1.21 — самая новая версия.", buttons: ["OK"]))
        let failed = UpdatePrompt.make(local: "0.1.20", fetch: .failure(.http(403)), text: ru)
        XCTAssertEqual(UpdateDialogs.prompt(failed, text: ru),
                       UpdateDialog(title: "Не удалось проверить обновления", text: "GitHub ответил кодом 403 — попробуйте позже",
                                    buttons: ["Повторить", "OK"]))
    }

    func testTheAvailableAlertCarriesNotesAndTheNotesButtonOnlyWithAPage() {
        let page = URL(string: "https://x.test/r")
        XCTAssertEqual(UpdateDialogs.prompt(.available(remote: "v0.1.22", local: "0.1.21", notes: "Fixes", url: page), text: ru),
                       UpdateDialog(title: "Вышла новая версия ox-say v0.1.22", text: "У вас v0.1.21.\n\nFixes",
                                    buttons: ["Обновить", "Позже", "Что нового…"]))
        XCTAssertEqual(UpdateDialogs.prompt(.available(remote: "v0.1.22", local: "0.1.21", notes: "", url: nil), text: en),
                       UpdateDialog(title: "ox-say v0.1.22 is available", text: "You have v0.1.21.", buttons: ["Update", "Later"]))
    }

    func testEveryUpdateErrorReadsRightInBothLanguages() {
        XCTAssertEqual(UpdateError.unreachable("offline").message(text: en), "Update check failed (offline)")
        XCTAssertEqual(UpdateError.unreachable("offline").message(text: ru), "Не удалось проверить обновления (offline)")
        XCTAssertEqual(UpdateError.http(503).message(text: en), "GitHub answered 503 — try again later")
        XCTAssertEqual(UpdateError.http(503).message(text: ru), "GitHub ответил кодом 503 — попробуйте позже")
        XCTAssertEqual(UpdateError.badResponse.message(text: en), "GitHub sent a release response without a tag")
        XCTAssertEqual(UpdateError.badResponse.message(text: ru), "GitHub прислал ответ о релизе без номера версии")
    }

    func testTheInstallPillAndTheMenuRowsAreInTheUsersLanguage() {
        XCTAssertEqual(UpdateInstaller.installingPill(kind: .update, tag: "v0.1.22", text: en), "Installing v0.1.22…")
        XCTAssertEqual(UpdateInstaller.installingPill(kind: .update, tag: "v0.1.22", text: ru), "Устанавливаю v0.1.22…")
        XCTAssertEqual(UpdateInstaller.installingPill(kind: .studioVoice, tag: "v0.1.22", text: ru), "Устанавливаю студийный голос…")
        XCTAssertEqual(UpdateInstaller.installingPill(kind: .studioVoice, tag: "v0.1.22", text: en), "Installing the studio voice…")
        XCTAssertEqual(en(.updateRepairItem), "Repair ox-say…")
        XCTAssertEqual(ru(.updateRepairItem), "Починить ox-say…")
        XCTAssertEqual(en(.updateFinishingPill), "Finishing the update…")
        XCTAssertEqual(ru(.updateFinishingPill), "Завершаю обновление…")
        XCTAssertEqual(StudioMenu.installTitle(text: ru), "Установить студийный голос (около 3 ГБ)…")
        XCTAssertEqual(StudioMenu.createVoiceTitle(text: ru), "Создать голос…")
        XCTAssertEqual(StudioMenu.cannotRunTitle(text: ru), "Этот Mac не может запустить студийный голос.")
        XCTAssertEqual(StudioMenu.unavailableText(reason: nil, text: ru), "Этот Mac не может запустить студийный голос.")
        let unavailable = DaemonStatus(version: "v0.1.21", studioAvailable: false, studioReason: nil, studioReasonCode: "model_missing")
        XCTAssertEqual(StudioMenu.rows(service: .answered(unavailable), installing: false, job: nil, serviceWaiting: false,
                                       hasOutputFolder: false, text: ru),
                       [.item(title: "Установить студийный голос (около 3 ГБ)…", isOn: false, isEnabled: true, action: .installStudioVoice)])
    }

    func testTheCreateAVoiceFormProblemsAreInTheUsersLanguage() {
        func problem(_ d: String, _ s: String, _ n: String) -> String? { DesignForm.problem(description: d, sentence: s, name: n, text: ru) }
        XCTAssertEqual(problem(" ", "x", "a"), "Сначала опишите голос.")
        XCTAssertEqual(problem(String(repeating: "d", count: 301), "x", "a"), "Описание слишком длинное: не больше 300 символов.")
        XCTAssertEqual(problem("d", "", "a"), "Напишите пробную фразу, которую произнесёт голос.")
        XCTAssertEqual(problem("d", String(repeating: "好", count: 81), "a"), "Пробная фраза слишком длинная: не больше 80 символов.")
        XCTAssertEqual(problem("d", "x", "Bad Name"),
                       "В имени можно использовать строчные английские буквы, цифры, - и _, до 32 символов; начинаться оно должно с буквы или цифры.")
        XCTAssertEqual(DesignForm.problem(description: "d", sentence: "x", name: "Bad Name", text: en),
                       "The name can use lowercase English letters, digits, - and _, up to 32 characters, and must start with a letter or digit.")
        XCTAssertEqual(DesignForm.problem(description: "d", sentence: String(repeating: "x", count: 201), name: "", text: en),
                       "The sample sentence is too long: keep it under 200 characters.")
    }

    func testTheTakeReviewTextsAreInTheUsersLanguage() {
        XCTAssertEqual(DesignForm.takeTitle(index: 1, count: 3, text: ru), "Вариант 2 из 3")
        XCTAssertEqual(DesignForm.warningText("it may contain babble", text: ru),
                       "В этом варианте могут быть посторонние звуки. Послушайте внимательно или возьмите следующий.")
        XCTAssertEqual(DesignForm.savedNotice(name: "anna", shortened: false, text: ru), "Голос «anna» сохранён")
        XCTAssertEqual(DesignForm.savedNotice(name: "anna", shortened: true, text: ru),
                       "Голос «anna» сохранён. Запись оказалась длиннее, чем голос может хранить, поэтому её сократили.")
        XCTAssertEqual(DesignForm.savedNotice(name: "anna", shortened: true, text: en),
                       "Voice “anna” saved. The recording was longer than a voice can keep, so it was shortened.")
        XCTAssertEqual(DesignForm.descriptionPlaceholder(text: ru),
                       "Тёплый женский голос диктора лет тридцати, носитель русского языка, живой и дружелюбный")
    }

    /// Keys only the AppKit glue reads (form labels, buttons, alert titles): both texts exist, differ, and keep their placeholders.
    func testEveryDialogKeyHasARealRussianText() {
        let enT = ShippedStrings.table("en"), ruT = ShippedStrings.table("ru")
        let mine = L10nKey.allCases.filter { $0.rawValue.hasPrefix("update.") && !$0.rawValue.hasPrefix("update.failed.")
            || $0.rawValue.hasPrefix("design.") || $0.rawValue.hasPrefix("studio.") }
        XCTAssertGreaterThan(mine.count, 40)
        for key in mine {
            let e = enT[key.rawValue] ?? "", r = ruT[key.rawValue] ?? ""
            XCTAssertFalse(e.isEmpty || r.isEmpty, key.rawValue)
            XCTAssertNotEqual(e, r, "\(key.rawValue) is not translated")
            XCTAssertNotNil(r.range(of: "[А-Яа-я]", options: .regularExpression), "\(key.rawValue) has no Russian")
            XCTAssertEqual(e.components(separatedBy: "%@").count, r.components(separatedBy: "%@").count, "\(key.rawValue): %@ count")
            XCTAssertEqual(e.contains("%1$@"), r.contains("%1$@"), key.rawValue)
        }
    }

    /// The retired English literals must not come back at their call sites. Mutation: AppDelegate.swift installUpdate,
    /// `UpdateInstaller.installingPill(kind: kind, tag: tag)` back to `"Installing \(tag)…"` -> RED.
    func testNoRetiredEnglishLiteralRemainsAtTheCallSites() throws {
        let app = try source("OxSayDictation/AppDelegate.swift")
        for literal in ["Wait for it to finish", "Repair ox-say?", "Install the studio voice?", "You're up to date", "Couldn't check for updates",
                        "is available\"", "You have v", "\"Release Notes", "\"Checking for updates", "\"Installing \\(", "\"Installing the studio voice",
                        "buttons: [\"OK\"]", "UpdateGate.busyAlertTitle,", "title: \"Repair ox-say", "Finishing the update…\")", "withTitle: \"Check for Updates"] {
            XCTAssertFalse(app.contains(literal), "AppDelegate.swift still has \(literal)")
        }
        XCTAssertTrue(app.contains("installPillText = UpdateInstaller.installingPill(kind: kind, tag: tag)"))
        XCTAssertTrue(app.contains("overlay.setWorkingText(L10nKey.updateCheckingPill.text)"))
        XCTAssertTrue(app.contains("runAlert(UpdateDialogs.repair(target: target))"))
        XCTAssertTrue(app.contains("runAlert(UpdateDialogs.studioVoice())"))
        XCTAssertEqual(app.components(separatedBy: "runAlert(UpdateDialogs.busy())").count - 1, 4, "the four install gates")
        let forms = try source("OxSayDictation/StudioForms.swift")
        for literal in ["Create a Voice\"", "Check the form", "Describe the voice\"", "Sample sentence", "Optional — ox-say", "withTitle: \"Create\"", "withTitle: \"OK\"", "withTitle: \"Cancel\""] {
            XCTAssertFalse(forms.contains(literal), "StudioForms.swift still has \(literal)")
        }
        let designer = try source("OxSayDictation/VoiceDesigner.swift")
        for literal in ["Designing a voice", "Couldn't create", "Couldn't play", "Couldn't save", "\"Keep This Voice\"", "\"Next Take\"", "\"Play Again\"", "It will be saved", "Replace it with", "\"OK\""] {
            XCTAssertFalse(designer.contains(literal), "VoiceDesigner.swift still has \(literal)")
        }
        let design = try source("DictationCore/DesignModels.swift")
        for literal in ["Describe the voice first", "too long: keep", "Write a sample sentence", "The name can use", "Take \\(", "stray sounds", "was longer than a voice"] {
            XCTAssertFalse(design.contains(literal), "DesignModels.swift still has \(literal)")
        }
        let menu = try source("DictationCore/StudioMenu.swift")
        for literal in ["Install Studio Voice", "Create a Voice…", "can't run the studio voice"] {
            XCTAssertFalse(menu.contains(literal), "StudioMenu.swift still has \(literal)")
        }
    }
}
