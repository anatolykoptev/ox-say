import Foundation

/// A voiceover the window is told to open (a notification's click, the menu's Stop row). The cached list is never the judge
/// of whether it exists: it predates a project that just finished, and the daemon's list is capped at the newest 20. The
/// project is asked for by id, and only the daemon's "not found" drops it. (A project id restored from the last run is
/// different: it waits for the first fresh list, `MainRoute.pruned`.)
public enum SpeakTarget {
    public enum Outcome: Equatable {
        /// The list on screen already has it.
        case cached
        /// Not on the list, but the daemon has it: the project to put on the list and open.
        case fetched(ProduceJob)
        /// The daemon does not have it (deleted), or did not answer: nothing is opened and the selection stays.
        case gone
    }

    public static func resolve(id: String, cached: [ProduceJob], fetch: (String) async throws -> ProduceJob) async -> Outcome {
        if cached.contains(where: { $0.id == id }) { return .cached }
        do {
            return .fetched(try await fetch(id))
        } catch {
            return .gone
        }
    }
}
