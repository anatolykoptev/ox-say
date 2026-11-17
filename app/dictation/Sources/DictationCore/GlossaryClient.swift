import Foundation

/// How the daemon labels a pair. A status a newer daemon adds is kept, not dropped.
public enum GlossaryStatus: Equatable {
    case candidate, active, rejected
    case unknown(String)

    init(_ raw: String) {
        switch raw {
        case "candidate": self = .candidate
        case "active": self = .active
        case "rejected": self = .rejected
        default: self = .unknown(raw)
        }
    }
}

/// One heard -> meant pair as the daemon lists it.
public struct GlossaryPair: Equatable, Identifiable {
    public let id: String
    public let heard: String
    public let meant: String
    public let status: GlossaryStatus
    /// How many times an agent filed it.
    public let seen: Int
    /// The distinct sentences the pair has been heard in (the daemon lists their hashes, never the sentences).
    public let sightings: Int
    /// How many of those came from a later dictation carrying the heard form again; the rest an agent filed.
    public let seenDictation: Int
    /// The sentences it needs to activate on its own evidence; 0 when an older daemon does not say.
    public let needed: Int

    public init(id: String, heard: String, meant: String, status: GlossaryStatus, seen: Int,
                sightings: Int = 0, seenDictation: Int = 0, needed: Int = 0) {
        self.id = id
        self.heard = heard
        self.meant = meant
        self.status = status
        self.seen = seen
        self.sightings = sightings
        self.seenDictation = seenDictation
        self.needed = needed
    }

    /// The evidence cell: a candidate shows its progress toward activation («1 из 2»); any other pair, or a
    /// candidate whose daemon does not say what it needs, shows the plain count of sentences.
    public var progressText: String {
        if status == .candidate, needed > 0 {
            return L10nKey.glossaryProgress.text(String(min(sightings, needed)), String(needed))
        }
        return String(sightings)
    }

    /// Where the sightings came from, for the row's tooltip: sentences, counted in the words of the language.
    public var provenanceText: String {
        L10nKey.glossaryProvenance.text(Self.sentences(seenDictation), Self.sentences(max(0, sightings - seenDictation)))
    }

    /// "1 sentence" / "2 sentences" / «5 предложений»: the plural form is the language's, named by the
    /// `glossary.plural.rule` string (`one-other` or `slavic`) so a language added later says its own rule.
    static func sentences(_ n: Int) -> String {
        let slavic = L10nKey.glossaryPluralRule.text == "slavic"
        let tail = n % 100
        let key: L10nKey
        switch (slavic, n % 10) {
        case (true, 1) where tail != 11, (false, _) where n == 1: key = .glossarySentencesOne
        case (true, 2...4) where !(12...14).contains(tail): key = .glossarySentencesFew
        default: key = .glossarySentencesMany
        }
        return key.text(String(n))
    }

    /// `{"pairs":[…]}`; nil when it is not that. A row with no id, heard or meant is skipped, never shown half.
    static func decodeList(_ data: Data) -> [GlossaryPair]? {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = top["pairs"] as? [[String: Any]] else { return nil }
        return rows.compactMap(decode)
    }

    /// One pair object (the answer to a filing); nil when it lacks an id, heard or meant.
    static func decodeOne(_ data: Data) -> GlossaryPair? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap(decode)
    }

    private static func decode(_ row: [String: Any]) -> GlossaryPair? {
        guard let id = row["id"] as? String, !id.isEmpty, let heard = row["heard"] as? String,
              let meant = row["meant"] as? String else { return nil }
        return GlossaryPair(id: id, heard: heard, meant: meant, status: GlossaryStatus(row["status"] as? String ?? ""),
                            seen: (row["seen"] as? Int) ?? 0, sightings: (row["sightings"] as? [Any])?.count ?? 0,
                            seenDictation: (row["seen_dictation"] as? Int) ?? 0, needed: (row["needed"] as? Int) ?? 0)
    }
}

/// Why an owner action was not even sent, or was refused as not the owner's.
public enum GlossaryError: Error, Equatable {
    /// `owner.token` is missing or unreadable: nothing was sent.
    case ownerTokenMissing
    /// The daemon answered 403: the token on disk is not the one it holds (it was regenerated, or the app reads another home).
    case ownerDenied

    public func message(text: (L10nKey) -> String = { $0.text }) -> String {
        switch self {
        case .ownerTokenMissing: return text(.glossaryOwnerMissing)
        case .ownerDenied: return text(.glossaryOwnerDenied)
        }
    }
}

/// The glossary calls to the ox-say daemon, on the studio client's transport and error handling. Listing and filing
/// are open on the daemon; approve, reject, edit and delete need the owner bearer, which `ownerToken` reads when a
/// request is made (the app passes `OwnerToken.read` on the daemon's home) and is never kept here.
public struct GlossaryClient {
    public var studio: StudioClient
    public var ownerToken: () -> String?

    public init(studio: StudioClient = StudioClient(), ownerToken: @escaping () -> String?) {
        self.studio = studio
        self.ownerToken = ownerToken
    }

    /// The app's own client: the daemon's address from the LaunchAgent, the token from the daemon's home.
    public static func current() -> GlossaryClient {
        let address = DaemonAddress.url(agentPlist: try? Data(contentsOf: DaemonAddress.agentPlist))
        let home = DaemonHome.current()
        return GlossaryClient(studio: StudioClient(baseURL: address), ownerToken: { OwnerToken.read(home: home) })
    }

    /// Whether the owner actions can be sent right now. The page reads this to say why they are off.
    public var canActAsOwner: Bool { ownerToken() != nil }

    /// GET /v1/glossary: every pair.
    public func pairs() async throws -> [GlossaryPair] {
        let data = try await studio.succeed(studio.get("v1/glossary"))
        guard let list = GlossaryPair.decodeList(data) else { throw StudioError.badResponse }
        return list
    }

    /// POST /v1/glossary: files a pair as a candidate (open to agents; the owner then approves it). The answer is the pair,
    /// whose id the owner's approval needs.
    @discardableResult
    public func add(heard: String, meant: String) async throws -> GlossaryPair {
        let body = try JSONSerialization.data(withJSONObject: ["heard": heard, "meant": meant], options: [.sortedKeys])
        let data = try await studio.succeed(studio.post("v1/glossary", body: body, timeout: StudioClient.quickTimeout))
        guard let pair = GlossaryPair.decodeOne(data) else { throw StudioError.badResponse }
        return pair
    }

    /// POST /v1/glossary/{id}/approve and /reject. Owner-only.
    public func approve(id: String) async throws { try await owner(id, "/approve", method: "POST", body: nil) }
    public func reject(id: String) async throws { try await owner(id, "/reject", method: "POST", body: nil) }

    /// POST /v1/glossary/{id}/edit: another meant form. Owner-only.
    public func edit(id: String, meant: String) async throws {
        try await owner(id, "/edit", method: "POST", body: try JSONSerialization.data(withJSONObject: ["meant": meant]))
    }

    /// DELETE /v1/glossary/{id}: removes the pair for good, no tombstone. Owner-only.
    public func purge(id: String) async throws { try await owner(id, "", method: "DELETE", body: nil) }

    /// One owner request: the id must be one plain path segment, the token is read now, and a 403 is `ownerDenied`.
    private func owner(_ id: String, _ tail: String, method: String, body: Data?) async throws {
        guard MeetingID.isSafe(id) else { throw StudioError.badResponse }
        guard let token = ownerToken() else { throw GlossaryError.ownerTokenMissing }
        var request = studio.post("v1/glossary/\(id)\(tail)", body: body, timeout: StudioClient.quickTimeout)
        request.httpMethod = method
        if method == "DELETE" { request.httpBody = nil }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await studio.perform(request)
        if status == 403 { throw GlossaryError.ownerDenied }
        guard (200..<300).contains(status) else { throw StudioClient.refusal(status: status, body: data) }
    }
}
