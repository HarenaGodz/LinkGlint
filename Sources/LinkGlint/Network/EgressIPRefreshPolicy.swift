import Foundation

enum EgressIPRefreshPolicy {
    static let refreshIntervalWhenPanelOpen: TimeInterval = 8
    static let refreshIntervalWhenPanelClosed: TimeInterval = 60
    static let refreshIntervalWhenPanelOpenVPNActive: TimeInterval = 2
    static let refreshIntervalWhenPanelClosedVPNActive: TimeInterval = 15
    static let failureRetryInterval: TimeInterval = 2
    static let maxConsecutiveFailureRetries = 3
    static let burstRefreshDelays: [TimeInterval] = [0.5, 2, 5]

    static func refreshInterval(panelOpen: Bool, vpnActive: Bool) -> TimeInterval {
        if vpnActive {
            return panelOpen
                ? refreshIntervalWhenPanelOpenVPNActive
                : refreshIntervalWhenPanelClosedVPNActive
        }
        return panelOpen ? refreshIntervalWhenPanelOpen : refreshIntervalWhenPanelClosed
    }

    static func failureRetryInterval(panelOpen: Bool, vpnActive: Bool) -> TimeInterval {
        guard panelOpen || vpnActive else { return refreshIntervalWhenPanelClosed }
        return failureRetryInterval
    }

    static func shouldScheduleFailureRetry(panelOpen: Bool, vpnActive: Bool, attempt: Int) -> Bool {
        (panelOpen || vpnActive) && attempt < maxConsecutiveFailureRetries
    }
}

struct EgressIPRequestCoalescer {
    private(set) var inFlight = false
    private var pendingForcedRefresh = false

    mutating func begin(force: Bool) -> Bool {
        guard !inFlight else {
            pendingForcedRefresh = pendingForcedRefresh || force
            return false
        }
        inFlight = true
        return true
    }

    /// Completes the current request and reports whether one forced follow-up
    /// was coalesced while it was running.
    mutating func finish() -> Bool {
        inFlight = false
        let followUp = pendingForcedRefresh
        pendingForcedRefresh = false
        return followUp
    }

    mutating func cancel() {
        inFlight = false
        pendingForcedRefresh = false
    }
}
