import Foundation
import XCTest
@testable import DictationCore

/// The page's AppKit and SwiftUI glue cannot run under the shim; what it decides is in DictationCore (`PhraseEditing`,
/// `PhraseRegeneration`, `SpeakStudio`) and tested there. These read the glue as text, without comments, and pin the calls
/// no behavioural test sees: that the decisions are the ones consulted.
final class SpeakPhrasesWiringTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return MeetingWiringTests.stripComments(try String(contentsOf: root.appendingPathComponent("Sources/\(relative)"), encoding: .utf8))
    }

    private func body(_ text: String, of signature: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), "\(signature) not found")
        let rest = text[start.lowerBound...]
        var end = rest.endIndex
        if let next = rest.dropFirst(signature.count).range(of: "\n    func |\n    private func |\n    // MARK", options: .regularExpression) {
            end = next.lowerBound
        }
        return String(rest[..<end])
    }

    /// Every change to a phrase goes through one gate that asks `canEditText`, so none is sent to a project that runs (the
    /// daemon refuses it) and none can skip the gate by being added later without it.
    /// Mutation: SpeakSource.phraseOperation, delete `PhraseEditing.canEditText(status: job.status)` -> RED here.
    func testEditTextIsGatedByTheJobState() throws {
        let speak = try source("OxSayDictation/SpeakSource.swift")
        let gate = try body(speak, of: "private func phraseOperation(")
        XCTAssertTrue(gate.contains("PhraseEditing.canEditText(status: job.status)"))
        XCTAssertTrue(gate.contains("!PhraseEditing.isBusy(model.data.speak.phraseWork, project: job.id)"), "one change at a time on a project")
        XCTAssertTrue(gate.contains("PhraseWork(project: job.id, chunk: n, kind: kind)"))
        for entry in ["func editPhraseText(", "func setMood(", "func anotherVariant(", "func pickOtherVariant("] {
            let function = try body(speak, of: entry)
            XCTAssertTrue(function.contains("phraseOperation(chunk: n"), "\(entry) bypasses the gate")
        }
    }

    /// A new reel sends the Reels preset, and a variant on one phrase goes through the ordered flow, never a bare pick.
    /// Mutation: SpeakSource.generateStudio, `reel: speak.reel` -> `reel: false` -> RED; anotherVariant, the `PhraseRegeneration.run`
    /// call replaced by a direct `client.pick` -> RED.
    func testAReelSendsItsPresetAndAVariantGoesThroughTheOrderedFlow() throws {
        let speak = try source("OxSayDictation/SpeakSource.swift")
        let studio = try body(speak, of: "private func generateStudio() {")
        XCTAssertTrue(studio.contains("SpeakStudio.start(text: speak.text, reel: speak.reel, advanced: model.advanced, panel: speak.panel)"))
        let variant = try body(speak, of: "func anotherVariant(")
        XCTAssertTrue(variant.contains("PhraseRegeneration.run(chunk: n, known: known"))
        XCTAssertTrue(variant.contains("waitUntilIdle: { try await voiceover.followAndWait(id: id) }"))
    }

    /// A refused start keeps the person's text: the failure path sets the phase and nothing else about the editor.
    /// Mutation: SpeakSource.generateStudio catch, add `self.model.data.speak.text = ""` -> RED.
    func testARefusedStartKeepsTheText() throws {
        let speak = try source("OxSayDictation/SpeakSource.swift")
        let studio = try body(speak, of: "private func generateStudio() {")
        let failure = try XCTUnwrap(studio.range(of: "} catch {"))
        let tail = String(studio[failure.lowerBound...])
        XCTAssertTrue(tail.contains("self.model.data.speak.phase = .failed(StudioError.plain(error))"))
        XCTAssertFalse(tail.contains("speak.text ="))
        XCTAssertFalse(tail.contains("newText()"))
    }

    /// The document opens from the page through `.fileImporter`; the over-the-cap offer and the mood chips are drawn only
    /// where DictationCore says so.
    /// Mutation: SpeakPage, delete `SpeakStudio.offersFirstPart(text:` condition -> RED; PhraseList, `if showsMood` -> `if true` -> RED.
    func testThePageDrawsTheOfferAndTheChipsOnlyWhereTheCoreDecides() throws {
        let page = try source("MainWindowUI/SpeakPage.swift")
        XCTAssertTrue(page.contains(".fileImporter(isPresented: $choosingDocument, allowedContentTypes: Self.documentTypes)"))
        XCTAssertTrue(page.contains("DocumentReader.supportedExtensions.compactMap { UTType(filenameExtension: $0) }"))
        XCTAssertTrue(page.contains("if SpeakStudio.offersFirstPart(text: values.text, engine: values.engine)"))
        XCTAssertTrue(page.contains("if model.data.speak.studio == .available {"), "the reel button needs the studio voice")
        let list = try source("MainWindowUI/PhraseList.swift")
        XCTAssertTrue(list.contains("values.showsMood(voices: model.data.voices.entries)"))
        XCTAssertTrue(list.contains("if showsMood {"))
        XCTAssertTrue(list.contains("let busy = PhraseEditing.isBusy(values.phraseWork, project: job.id) || !PhraseEditing.canEditText(status: job.status)"))
        let values = try source("MainWindowUI/SpeakValues.swift")
        XCTAssertTrue(values.contains("PhraseEditing.showsMood(voice: selectedID.flatMap { projectVoices[$0] }, voices: voices, advanced: advanced, copiesRecordingStyle: copiesRecordingStyle)"))
    }

    /// The decisions the page makes at its call sites, pinned because no behavioural test sees them.
    /// Mutation: SpeakSource.generateStudio, delete the `rememberVoice` line (the mood chips then never appear in the simple
    /// mode) -> RED; setMood, inline `style: mood?.styleWord` (the `no mood` choice would send a nil style) -> RED;
    /// MainWindowSource, delete `a.phraseMood = …` (the chip does nothing) -> RED.
    func testTheCallSitesUseTheCoreDecisions() throws {
        let speak = try source("OxSayDictation/SpeakSource.swift")
        let studio = try body(speak, of: "private func generateStudio() {")
        XCTAssertTrue(studio.contains("SpeakStudio.rememberVoice(voice, for: job.id, in: self.model.data.speak.projectVoices)"))
        let mood = try body(speak, of: "func setMood(")
        XCTAssertTrue(mood.contains("PhraseEditing.deliveryEntry(chunk: n, mood: mood)"))
        XCTAssertFalse(mood.contains("styleWord"))
        let window = try source("OxSayDictation/MainWindowSource.swift")
        for line in [
            "a.speakNewReel = { [weak self] in self?.speakSource.newReel() }",
            "a.speakOpenDocument = { [weak self] url in self?.speakSource.openDocument(url) }",
            "a.speakKeepFirstPart = { [weak self] in self?.speakSource.keepFirstPart() }",
            "a.phrasePlay = { [weak self] n in self?.speakSource.playPhrase(n) }",
            "a.phraseVariant = { [weak self] n in self?.speakSource.anotherVariant(n) }",
            "a.phrasePickOther = { [weak self] n in self?.speakSource.pickOtherVariant(n) }",
            "a.phraseMood = { [weak self] n, mood in self?.speakSource.setMood(n, mood) }",
            "a.phraseEditText = { [weak self] n, text in self?.speakSource.editPhraseText(n, text) }",
            "a.speakGenerate = { [weak self] in self?.speakSource.generate() }",
            "a.speakNewText = { [weak self] in self?.speakSource.newText() }",
        ] {
            XCTAssertTrue(window.contains(line), "MainWindowSource lost `\(line)`")
        }
    }

    /// A reel is a draft: it does not change the saved «Качество», and it ends when the person leaves it (a new text, a clip
    /// or a project selected, a project started), so a later «Озвучить» never sends the Reels preset by accident.
    /// Mutation: SpeakSource.newReel, add `qualityChanged(.studio)` -> RED; select(_:) or selectProject, delete `endReel()` -> RED.
    func testAReelDoesNotChangeTheSavedQualityAndEndsWhenLeft() throws {
        let speak = try source("OxSayDictation/SpeakSource.swift")
        let reel = try body(speak, of: "func newReel() {")
        XCTAssertFalse(reel.contains("qualityChanged("))
        XCTAssertFalse(reel.contains("defaults.set"))
        XCTAssertTrue(reel.contains("model.data.speak.quality = .studio"))
        let end = try body(speak, of: "private func endReel() {")
        XCTAssertTrue(end.contains("host.defaults.string(forKey: Self.qualityKey)"), "leaving a reel restores the saved quality")
        for entry in ["func newText() {", "func select(_ id: String) {", "private func selectProject(_ id: String) {"] {
            let function = try body(speak, of: entry)
            XCTAssertTrue(function.contains("endReel()"), "\(entry) leaves the reel preset on")
        }
        let list = try source("MainWindowUI/PhraseList.swift")
        XCTAssertTrue(list.contains("PhraseEditing.shownWork(values.phraseWork, project: job.id, chunk: row.index)"))
        XCTAssertTrue(list.contains("PhraseEditing.isBusy(values.phraseWork, project: job.id)"))
        let service = try source("OxSayDictation/VoiceoverService.swift")
        XCTAssertTrue(service.contains("try JobWait.requireFinished(ended)"))
        let page = try source("MainWindowUI/SpeakPage.swift")
        XCTAssertTrue(page.contains(".labelStyle(.titleAndIcon)"), "the reel button is found by its name, not by a glyph")
    }
}
