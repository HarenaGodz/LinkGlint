import Foundation

protocol MonotonicClock {
    var now: TimeInterval { get }
}

struct SystemMonotonicClock: MonotonicClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

protocol RefreshScheduling {
    func schedule(_ workItem: DispatchWorkItem, after delay: TimeInterval)
}

struct DispatchRefreshScheduler: RefreshScheduling {
    let queue: DispatchQueue

    init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    func schedule(_ workItem: DispatchWorkItem, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + max(delay, 0), execute: workItem)
    }
}
