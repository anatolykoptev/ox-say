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

/// What the app reads and sends for the code vocabulary setting: the enabled packs as a set.
public enum CodeVocabulary {
    /// The enabled packs of a settings answer. nil for an answer without the field (a daemon without packs) or one
    /// that is not a list of strings: a guess could show a switch off over one that is on. Pack ids this app does not
    /// know are ignored — a newer daemon may carry more.
    public static func decode(_ data: Data) -> Set<CodePack>? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let names = obj["code_vocabulary"] as? [String] else { return nil }
        return Set(names.compactMap(CodePack.init(rawValue:)))
    }

    /// The PUT body: the packs in the canonical order, so one choice is always one body.
    public static func body(_ packs: Set<CodePack>) throws -> Data {
        let names = CodePack.allCases.filter(packs.contains).map(\.rawValue)
        return try JSONSerialization.data(withJSONObject: ["code_vocabulary": names])
    }

    /// The set after one switch was flipped.
    public static func toggled(_ packs: Set<CodePack>, _ pack: CodePack, on: Bool) -> Set<CodePack> {
        var out = packs
        if on { out.insert(pack) } else { out.remove(pack) }
        return out
    }
}

extension StudioClient {
    /// GET /v1/meetings/settings, the `code_vocabulary` field: the packs that are on.
    public func codeVocabulary() async throws -> Set<CodePack> {
        let data = try await succeed(get("v1/meetings/settings"))
        guard let packs = CodeVocabulary.decode(data) else { throw StudioError.badResponse }
        return packs
    }

    /// PUT /v1/meetings/settings: switches the packs; the daemon rebuilds its decoder list at once.
    public func setCodeVocabulary(_ packs: Set<CodePack>) async throws {
        var request = post("v1/meetings/settings", body: try CodeVocabulary.body(packs), timeout: Self.quickTimeout)
        request.httpMethod = "PUT"
        _ = try await succeed(request)
    }
}
