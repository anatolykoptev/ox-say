import Foundation

/// The built-in code vocabulary packs the daemon offers (`code_vocabulary` in `GET /v1/meetings/settings`). `rawValue`
/// is the pack id the daemon accepts. The packs are for dictating about code: they steer the recogniser towards
/// identifiers, so they stay off until the user turns one on.
public enum CodePack: String, CaseIterable, Sendable {
    case python
    case go
    case rust

    /// The language's own name; it is the same in every UI language.
    public var title: String {
        switch self {
        case .python: return "Python"
        case .go: return "Go"
        case .rust: return "Rust"
        }
    }
}

/// What the daemon answered: the packs this app knows, and the ids it does not (a newer daemon may carry more).
public struct CodeVocabularyAnswer: Equatable, Sendable {
    public var packs: Set<CodePack>
    public var unknown: [String]

    public init(packs: Set<CodePack>, unknown: [String] = []) {
        self.packs = packs
        self.unknown = unknown
    }
}

/// What the app reads and sends for the code vocabulary setting.
public enum CodeVocabulary {
    /// The enabled packs of a settings answer. nil for an answer without the field (a daemon without packs) or one
    /// that is not a list of strings: a guess could show a switch off over one that is on. Ids this app does not know
    /// are kept apart, so a save can send them back instead of clearing them.
    public static func decodeAnswer(_ data: Data) -> CodeVocabularyAnswer? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let names = obj["code_vocabulary"] as? [String] else { return nil }
        return CodeVocabularyAnswer(packs: Set(names.compactMap(CodePack.init(rawValue:))),
                                    unknown: names.filter { CodePack(rawValue: $0) == nil })
    }

    public static func decode(_ data: Data) -> Set<CodePack>? { decodeAnswer(data)?.packs }

    /// The PUT body: the packs in the canonical order, then the ids this app does not know, so one choice is always
    /// one body.
    public static func body(_ packs: Set<CodePack>, keeping unknown: [String] = []) throws -> Data {
        let names = CodePack.allCases.filter(packs.contains).map(\.rawValue) + unknown
        return try JSONSerialization.data(withJSONObject: ["code_vocabulary": names])
    }

    /// The set after one switch was flipped.
    public static func toggled(_ packs: Set<CodePack>, _ pack: CodePack, on: Bool) -> Set<CodePack> {
        var out = packs
        if on { out.insert(pack) } else { out.remove(pack) }
        return out
    }
}

/// Sends the switches to the daemon one request at a time, newest intent last. A flip while a save is in flight only
/// records the new set; when the save returns, the latest set is sent. So the daemon always ends on what the user
/// chose last, and the page then shows what the daemon confirms (`apply`), not what was asked for.
@MainActor
public final class CodePackSync {
    private let put: (Set<CodePack>, [String]) async throws -> Void
    private let read: () async throws -> CodeVocabularyAnswer
    private let apply: (CodeVocabularyAnswer) -> Void
    private var desired: Set<CodePack> = []
    private var unknown: [String] = []
    private var dirty = false
    private var running = false

    public init(put: @escaping (Set<CodePack>, [String]) async throws -> Void,
                read: @escaping () async throws -> CodeVocabularyAnswer,
                apply: @escaping (CodeVocabularyAnswer) -> Void) {
        self.put = put
        self.read = read
        self.apply = apply
    }

    /// True while a choice is being sent or waits to be: a settings read must not overwrite the page then.
    public var isBusy: Bool { running || dirty }

    /// The ids the daemon carries that this app cannot show; they ride along on every save.
    public func learn(_ answer: CodeVocabularyAnswer) { unknown = answer.unknown }

    /// The user's latest choice. A call made while a save runs returns at once; the running call sends it next.
    public func choose(_ packs: Set<CodePack>) async {
        desired = packs
        dirty = true
        if running { return }
        running = true
        while dirty {
            dirty = false
            let want = desired
            do { try await put(want, unknown) } catch { /* the confirmed read below shows what the daemon holds */ }
        }
        if let answer = try? await read() {
            unknown = answer.unknown
            // a flip that landed during the read is not overwritten by an older answer
            if !dirty { apply(answer) }
        }
        running = false
        if dirty { await choose(desired) }
    }
}

extension StudioClient {
    /// GET /v1/meetings/settings, the `code_vocabulary` field.
    public func codeVocabularyAnswer() async throws -> CodeVocabularyAnswer {
        let data = try await succeed(get("v1/meetings/settings"))
        guard let answer = CodeVocabulary.decodeAnswer(data) else { throw StudioError.badResponse }
        return answer
    }

    /// GET /v1/meetings/settings, the `code_vocabulary` field: the packs that are on.
    public func codeVocabulary() async throws -> Set<CodePack> { try await codeVocabularyAnswer().packs }

    /// PUT /v1/meetings/settings: switches the packs; the daemon rebuilds its decoder list at once.
    public func setCodeVocabulary(_ packs: Set<CodePack>, keeping unknown: [String] = []) async throws {
        var request = post("v1/meetings/settings", body: try CodeVocabulary.body(packs, keeping: unknown), timeout: Self.quickTimeout)
        request.httpMethod = "PUT"
        _ = try await succeed(request)
    }
}
