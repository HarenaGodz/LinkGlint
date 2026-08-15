import Foundation

/// Owns the mutable scheduling state for exit-IP refreshes. All callers use a
/// ticket tied to the current network generation, preventing a task launched
/// before sleep, a path change, or a VPN transition from overwriting new state.
final class EgressIPRefreshCoordinator {
    struct Ticket: Equatable {
        fileprivate let generation: Int
        fileprivate let sequence: UInt64
    }

    struct Completion: Equatable {
        let forcedFollowUp: Bool
    }

    private var requests = EgressIPRequestCoalescer()
    private var task: Task<Void, Never>?
    private var generation = 0
    private var nextSequence: UInt64 = 0
    private var activeTicket: Ticket?

    private(set) var lastSuccessUptime: TimeInterval?
    private(set) var consecutiveFailures = 0
    private(set) var geoCacheAddress: String?
    private(set) var geoCacheUptime: TimeInterval?
    let geoCacheLifetime: TimeInterval

    var failureRetryAttempt: Int { max(consecutiveFailures - 1, 0) }
    var currentGeneration: Int { generation }

    init(geoCacheLifetime: TimeInterval = 6 * 60 * 60) {
        self.geoCacheLifetime = geoCacheLifetime
    }

    func begin(
        force: Bool,
        now: TimeInterval,
        refreshInterval: TimeInterval
    ) -> Ticket? {
        if !force,
           let lastSuccessUptime,
           now >= lastSuccessUptime,
           now - lastSuccessUptime < refreshInterval {
            return nil
        }
        guard requests.begin(force: force) else { return nil }
        nextSequence &+= 1
        let ticket = Ticket(generation: generation, sequence: nextSequence)
        activeTicket = ticket
        return ticket
    }

    func attach(_ task: Task<Void, Never>, to ticket: Ticket) {
        guard activeTicket == ticket else {
            task.cancel()
            return
        }
        self.task = task
    }

    func completeSuccess(_ ticket: Ticket, now: TimeInterval) -> Completion? {
        guard activeTicket == ticket, ticket.generation == generation else { return nil }
        task = nil
        activeTicket = nil
        lastSuccessUptime = now
        consecutiveFailures = 0
        return Completion(forcedFollowUp: requests.finish())
    }

    func completeFailure(_ ticket: Ticket) -> Completion? {
        guard activeTicket == ticket, ticket.generation == generation else { return nil }
        task = nil
        activeTicket = nil
        consecutiveFailures += 1
        return Completion(forcedFollowUp: requests.finish())
    }

    func invalidateNetworkGeneration(clearSuccessTime: Bool = false) {
        generation &+= 1
        task?.cancel()
        task = nil
        activeTicket = nil
        requests.cancel()
        consecutiveFailures = 0
        if clearSuccessTime { lastSuccessUptime = nil }
    }

    func shouldRefreshGeo(
        for address: String,
        hasCachedValue: Bool,
        now: TimeInterval
    ) -> Bool {
        guard hasCachedValue,
              geoCacheAddress == address,
              let geoCacheUptime,
              now >= geoCacheUptime,
              now - geoCacheUptime < geoCacheLifetime else {
            return true
        }
        return false
    }

    func recordGeoSuccess(for address: String, now: TimeInterval) {
        geoCacheAddress = address
        geoCacheUptime = now
    }

    func clearGeoCache() {
        geoCacheAddress = nil
        geoCacheUptime = nil
    }
}
