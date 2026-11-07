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
        XCTAssertTrue(gate.contains("model.data.speak.phraseWork == nil"), "one change at a time")
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
        XCTAssertTrue(studio.contains("SpeakStudio.start(text: speak.text, reel: speak.reel)"))
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
        XCTAssertTrue(list.contains("let busy = values.phraseWork != nil || !PhraseEditing.canEditText(status: job.status)"))
        let values = try source("MainWindowUI/SpeakValues.swift")
        XCTAssertTrue(values.contains("PhraseEditing.showsMood(voice: selectedID.flatMap { projectVoices[$0] }, voices: voices, advanced: advanced)"))
    }
}
