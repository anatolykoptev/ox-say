import XCTest
@testable import DictationCore

final class DesignModelsTests: XCTestCase {
    func testDesignBodyUsesTheDaemonsKeysAndThreeTakes() throws {
        let body = DesignRequest.body(description: "  A warm narrator ", text: " Привет. ")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["description"] as? String, "A warm narrator")
        XCTAssertEqual(json["text"] as? String, "Привет.")
        XCTAssertEqual(json["takes"] as? Int, 3)
        XCTAssertEqual(Set(json.keys), ["description", "text", "takes"])
    }

    func testSaveBodyAddsReplaceOnlyWhenAsked() throws {
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: DesignRequest.saveBody(name: "anna", take: "/t/a.wav", replace: false)) as? [String: Any])
        XCTAssertEqual(Set(plain.keys), ["name", "take"])
        let replace = try XCTUnwrap(JSONSerialization.jsonObject(with: DesignRequest.saveBody(name: "anna", take: "/t/a.wav", replace: true)) as? [String: Any])
        XCTAssertEqual(replace["replace"] as? Bool, true)
        XCTAssertEqual(replace["take"] as? String, "/t/a.wav")
    }

    func testTakesDecode() throws {
        let data = Data(#"{"description":"d","text":"t","takes":[{"path":"/c/design/a.wav","seed":1,"duration_s":6.25,"suggested_name":"warm-narrator-1"},{"path":"/c/design/b.wav","seed":2,"duration_s":21,"suggested_name":"warm-narrator-2","warning":"this take is 21 s, too long to keep as a voice (the limit is 20 s): use a shorter line"}],"save_hint":"x"}"#.utf8)
        let takes = try XCTUnwrap(DesignTake.decodeAll(data))
        XCTAssertEqual(takes.count, 2)
        XCTAssertEqual(takes[0], DesignTake(path: "/c/design/a.wav", durationSeconds: 6.25, suggestedName: "warm-narrator-1"))
        XCTAssertEqual(takes[1].warning, "this take is 21 s, too long to keep as a voice (the limit is 20 s): use a shorter line")
        XCTAssertNil(DesignTake.decodeAll(Data(#"{"takes":[]}"#.utf8)))
    }

    func testNameValidationFollowsTheDaemonsRule() {
        for good in ["anna", "a", "warm-narrator-1", "a_b-c", "0abc", String(repeating: "a", count: 32)] {
            XCTAssertTrue(DesignForm.isValidName(good), good)
        }
        for bad in ["", "Anna", "-anna", "_anna", "an na", "анна", "a.b", String(repeating: "a", count: 33), "anna\n"] {
            XCTAssertFalse(DesignForm.isValidName(bad), bad)
        }
    }

    func testFormProblemsArePlainWords() {
        XCTAssertNil(DesignForm.problem(description: "A voice", sentence: DesignForm.defaultSentence, name: "anna-1"))
        XCTAssertEqual(DesignForm.problem(description: " ", sentence: "x", name: "a"), "Describe the voice first.")
        XCTAssertEqual(DesignForm.problem(description: "d", sentence: "", name: "a"), "Write a sample sentence for the voice to say.")
        XCTAssertNotNil(DesignForm.problem(description: String(repeating: "d", count: 301), sentence: "x", name: "a"))
        XCTAssertNotNil(DesignForm.problem(description: "d", sentence: String(repeating: "x", count: 201), name: "a"))
        XCTAssertNotNil(DesignForm.problem(description: "d", sentence: "x", name: "Bad Name"))
        XCTAssertNil(DesignForm.problem(description: "d", sentence: "x", name: ""), "an empty name takes the daemon's suggestion")
    }

    /// Same cases as the daemon's TestDesignTextCapFollowsSpokenDuration (internal/daemon/design_test.go): the cap is on
    /// spoken duration, so Chinese gets fewer characters than Russian. Mutation: DesignForm.sentenceUnits, price Han as
    /// Latin (drop the Han branch) -> RED on the "chinese 81", "chinese 150" and "mixed" rows.
    func testSentenceCapFollowsSpokenDurationLikeTheDaemon() {
        func rep(_ s: String, _ n: Int) -> String { String(repeating: s, count: n) }
        let rows: [(String, String, Bool)] = [
            ("cyrillic at the cap", rep("я", 200), true),
            ("cyrillic over", rep("я", 201), false),
            ("latin at the cap", rep("a", 200), true),
            ("chinese 80", rep("好", 80), true),
            ("chinese 81", rep("好", 81), false),
            ("chinese 150", rep("好", 150), false),
            ("kana 120", rep("あ", 120), true),
            ("kana 121", rep("あ", 121), false),
            ("hangul 121", rep("가", 121), false),
            ("thai 121", rep("ก", 121), false),
            ("mixed", rep("好", 60) + rep("a", 60), false),
        ]
        for (name, text, ok) in rows {
            let problem = DesignForm.problem(description: "d", sentence: text, name: "")
            XCTAssertEqual(problem == nil, ok, "\(name): \(problem ?? "accepted")")
        }
        XCTAssertEqual(DesignForm.problem(description: "d", sentence: rep("好", 150), name: ""),
                       "The sample sentence is too long: keep it under 80 characters.", "the refusal states its own cap")
        XCTAssertEqual(DesignForm.problem(description: "d", sentence: rep("я", 201), name: ""),
                       "The sample sentence is too long: keep it under 200 characters.")
        XCTAssertEqual(DesignForm.sentenceCap(for: rep("あ", 150)), 120)
        XCTAssertEqual(DesignForm.sentenceUnits(rep("好", 80)), 1200)
    }

    func testAnEmptyNameFallsBackToTheTakesSuggestion() {
        let take = DesignTake(path: "/t.wav", durationSeconds: 5, suggestedName: "warm-narrator-2")
        XCTAssertEqual(DesignForm.saveName(typed: "", take: take), "warm-narrator-2")
        XCTAssertEqual(DesignForm.saveName(typed: "anna", take: take), "anna")
    }

    func testTheDefaultSentenceFitsTheDaemonsLimit() {
        XCTAssertLessThan(DesignForm.defaultSentence.count, DesignForm.sentenceLimit)
    }

    func testTakeTitle() {
        XCTAssertEqual(DesignForm.takeTitle(index: 0, count: 3), "Take 1 of 3")
        XCTAssertEqual(DesignForm.takeTitle(index: 2, count: 3), "Take 3 of 3")
    }

    func testWarningsAreInPlainWords() {
        XCTAssertEqual(DesignForm.warningText("the take is 11.2 s, longer than its text plausibly needs (9.0 s): it may contain babble; re-render with another seed"),
                       "This take may contain stray sounds. Listen closely, or try the next take.")
        XCTAssertEqual(DesignForm.warningText("this take is 21 s, too long to keep as a voice (the limit is 20 s): use a shorter line"),
                       "This take is 21 s, too long to keep as a voice (the limit is 20 s): use a shorter line")
    }

    // MARK: save outcome

    /// Mutation: make SaveOutcome.interpret throw for 409 instead of returning .nameTaken -> RED.
    func testAnExistingNameLeadsToTheReplaceQuestion() throws {
        let body = Data(#"{"error":{"message":"a voice named \"anna\" already exists; choose another name or pass replace","type":"Conflict"}}"#.utf8)
        let outcome = try SaveOutcome.interpret(status: 409, data: body)
        XCTAssertEqual(outcome, .nameTaken)
    }

    func testASavedVoiceCarriesItsNameAndNotice() throws {
        let ok = Data(#"{"name":"anna","engine":"voxcpm2","designed_from":"d","seed":5,"registered_to_engine":true,"notice":"clip is longer"}"#.utf8)
        let outcome = try SaveOutcome.interpret(status: 200, data: ok)
        XCTAssertEqual(outcome, .saved(SavedVoice(name: "anna", notice: "clip is longer")))
    }

    func testOtherFailuresCarryTheDaemonsMessage() {
        let body = Data(#"{"error":{"message":"that is not a take made by voice design","type":"Bad Request"}}"#.utf8)
        func failure(_ status: Int, _ data: Data) -> StudioError? {
            do {
                _ = try SaveOutcome.interpret(status: status, data: data)
                return nil
            } catch {
                return error as? StudioError
            }
        }
        XCTAssertEqual(failure(400, body), .refused(status: 400, message: "that is not a take made by voice design"))
        XCTAssertEqual(failure(500, Data()), .refused(status: 500, message: "The ox-say service answered with an error (500)."))
    }

    func testSaveDesignClientRetriesWithReplaceAfterA409() async throws {
        var bodies: [[String: Any]] = []
        let client = StudioClient(send: { request in
            bodies.append(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:])
            let first = bodies.count == 1
            let response = HTTPURLResponse(url: request.url!, statusCode: first ? 409 : 200, httpVersion: nil, headerFields: nil)!
            return (first ? Data(#"{"error":{"message":"exists"}}"#.utf8) : Data(#"{"name":"anna"}"#.utf8), response)
        })
        let first = try await client.saveDesign(name: "anna", take: "/t.wav", replace: false)
        XCTAssertEqual(first, .nameTaken)
        let second = try await client.saveDesign(name: "anna", take: "/t.wav", replace: true)
        XCTAssertEqual(second, .saved(SavedVoice(name: "anna", notice: nil)))
        XCTAssertNil(bodies[0]["replace"])
        XCTAssertEqual(bodies[1]["replace"] as? Bool, true)
    }
}
