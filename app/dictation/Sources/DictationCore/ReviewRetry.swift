import Foundation

/// Review a script, then start it; when the start fails, review it again with
/// the text the person had. The daemon is the judge of what it accepts, so a
/// start it refuses (an unknown `[directive]`, say) must not throw away an
/// editing session that may be a whole cleaned-up book.
public enum ReviewRetry {
    /// - Parameters:
    ///   - draft: what the first review shows.
    ///   - review: shows a draft and returns the person's version, or nil when they cancel.
    ///   - start: starts the reviewed draft; throws when the daemon will not.
    ///   - failed: tells the person why the start failed, before the review reopens.
    /// - Returns: what `start` returned, or nil when the person cancelled.
    @MainActor
    public static func run<Draft, Started>(_ draft: Draft,
                                           review: (Draft) -> Draft?,
                                           start: (Draft) async throws -> Started,
                                           failed: (Error) -> Void) async -> Started? {
        var current = draft
        while let reviewed = review(current) {
            do {
                return try await start(reviewed)
            } catch {
                failed(error)
                current = reviewed
            }
        }
        return nil
    }
}
