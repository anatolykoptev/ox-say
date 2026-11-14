import Foundation
import SwiftUI

/// Which pairs the Glossary page lists.
public enum GlossaryFilter: CaseIterable, Equatable {
    case all, candidate, active, rejected

    func admits(_ status: GlossaryStatus) -> Bool {
        switch self {
        case .all: return true
        case .candidate: return status == .candidate
        case .active: return status == .active
        case .rejected: return status == .rejected
        }
    }

    public var titleKey: L10nKey {
        switch self {
        case .all: return .glossaryFilterAll
        case .candidate: return .glossaryFilterCandidate
        case .active: return .glossaryFilterActive
        case .rejected: return .glossaryFilterRejected
        }
    }
}

/// How the last read of the glossary went.
public enum GlossaryLoad: Equatable {
    case loading
    case loaded
    /// The sentence the person reads.
    case failed(String)
}

/// The Glossary page's state: the pairs as the daemon last listed them, the filter, and the owner actions. The list on
/// screen is always the daemon's: every action, refused or not, ends in a fresh read, and the model never edits its own
/// copy. No UI here, so the decisions are tested without a window.
@MainActor
public final class GlossaryModel: ObservableObject {
    @Published public private(set) var pairs: [GlossaryPair] = []
    @Published public var filter: GlossaryFilter = .all
    @Published public private(set) var load: GlossaryLoad = .loading
    /// An action is in flight: the page disables its buttons so two cannot overlap.
    @Published public private(set) var busy = false
    /// What the last action's failure says, in the person's words; cleared by the next action.
    @Published public private(set) var problem: String?
    /// Whether the owner token could be read at the last look. When it cannot, the page still lists and says why.
    @Published public private(set) var ownerAvailable: Bool

    private let client: GlossaryClient
    private let text: (L10nKey) -> String

    public init(client: GlossaryClient, text: @escaping (L10nKey) -> String = { $0.text }) {
        self.client = client
        self.text = text
        self.ownerAvailable = client.canActAsOwner
    }

    /// The pairs the filter admits, in the daemon's order.
    public var visible: [GlossaryPair] { pairs.filter { filter.admits($0.status) } }

    public func count(_ f: GlossaryFilter) -> Int { pairs.filter { f.admits($0.status) }.count }

    public func dismissProblem() { problem = nil }

    /// Reads the list from the daemon. A failed read keeps the last good list and says so.
    public func reload() async {
        ownerAvailable = client.canActAsOwner
        do {
            pairs = try await client.pairs()
            load = .loaded
        } catch {
            load = .failed(describe(error))
        }
    }

    public func approve(_ id: String) async { await act { try await self.client.approve(id: id) } }
    public func reject(_ id: String) async { await act { try await self.client.reject(id: id) } }
    public func delete(_ id: String) async { await act { try await self.client.purge(id: id) } }

    public func edit(_ id: String, meant: String) async {
        let meant = meant.trimmingCharacters(in: .whitespacesAndNewlines)
        await act { try await self.client.edit(id: id, meant: meant) }
    }

    /// The owner is present, so a pair filed here is approved at once: filing, then approving the id the daemon gave.
    /// Returns whether the pair went in, so the sheet knows to close.
    @discardableResult
    public func add(heard: String, meant: String) async -> Bool {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let meant = meant.trimmingCharacters(in: .whitespacesAndNewlines)
        return await act {
            let pair = try await self.client.add(heard: heard, meant: meant)
            try await self.client.approve(id: pair.id)
        }
    }

    /// Runs one action, then reads the list again whatever happened: a refusal may mean the daemon's list is not what
    /// the page showed. Returns whether the action itself went through.
    @discardableResult
    private func act(_ action: () async throws -> Void) async -> Bool {
        guard !busy else { return false }
        busy = true
        problem = nil
        var ok = true
        do { try await action() } catch {
            ok = false
            problem = describe(error)
        }
        await reload()
        busy = false
        return ok
    }

    private func describe(_ error: Error) -> String {
        if let g = error as? GlossaryError { return g.message(text: text) }
        return StudioError.plain(error, text: text)
    }
}
