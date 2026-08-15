import Foundation

/// Coalesces periodic, user-forced and post-mutation refreshes while exposing a
/// generation token that invalidates results from an older network topology.
final class NetworkRefreshCoordinator {
    private var requests = RefreshRequestCoalescer()
    private var deferredShowsErrors: Bool?
    private(set) var generation = 0

    func invalidateGeneration() {
        generation &+= 1
    }

    /// Returns the effective error-reporting behavior when a refresh should
    /// start, or nil when the request was deferred/coalesced.
    func request(showingErrors: Bool, mutationActive: Bool) -> Bool? {
        guard !mutationActive else {
            deferredShowsErrors = (deferredShowsErrors ?? false) || showingErrors
            return nil
        }
        let effective = (deferredShowsErrors ?? false) || showingErrors
        deferredShowsErrors = nil
        guard requests.request(showingErrors: effective) else { return nil }
        return effective
    }

    /// Finishes an active request and returns one combined follow-up, if any.
    func finish(retryingWith retryShowsErrors: Bool? = nil) -> Bool? {
        let pending = requests.finish()
        guard pending != nil || retryShowsErrors != nil else { return nil }
        return (pending ?? false) || (retryShowsErrors ?? false)
    }
}
