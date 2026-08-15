import Foundation

protocol InterfaceTrafficSampling {
    func fetchTrafficCounters() throws -> [String: InterfaceCounters]
}

protocol ProcessTrafficSampling {
    func fetchProcessTrafficCounters() throws -> [String: ProcessTrafficCounters]
}

protocol VPNInterfaceProviding {
    func fetchActiveVPNInterfaceNames() -> Set<String>
}

final class TrafficMonitoringCoordinator {
    enum Pipeline: CaseIterable, Hashable {
        case interface
        case process
        case vpn
    }

    struct Ticket: Equatable {
        fileprivate let pipeline: Pipeline
        fileprivate let generation: Int
        fileprivate let sequence: UInt64
    }

    private struct State {
        var generation = 0
        var nextSequence: UInt64 = 0
        var activeTicket: Ticket?
    }

    private var states = Dictionary(
        uniqueKeysWithValues: Pipeline.allCases.map { ($0, State()) }
    )

    func begin(_ pipeline: Pipeline) -> Ticket? {
        guard var state = states[pipeline], state.activeTicket == nil else { return nil }
        state.nextSequence &+= 1
        let ticket = Ticket(
            pipeline: pipeline,
            generation: state.generation,
            sequence: state.nextSequence
        )
        state.activeTicket = ticket
        states[pipeline] = state
        return ticket
    }

    /// Returns false when a completion belongs to a cancelled/older generation.
    func complete(_ ticket: Ticket) -> Bool {
        guard var state = states[ticket.pipeline],
              state.activeTicket == ticket,
              state.generation == ticket.generation else { return false }
        state.activeTicket = nil
        states[ticket.pipeline] = state
        return true
    }

    func invalidate(_ pipeline: Pipeline) {
        guard var state = states[pipeline] else { return }
        state.generation &+= 1
        state.activeTicket = nil
        states[pipeline] = state
    }

    func invalidateAll() {
        for pipeline in Pipeline.allCases { invalidate(pipeline) }
    }

    func isRunning(_ pipeline: Pipeline) -> Bool {
        states[pipeline]?.activeTicket != nil
    }
}

struct VPNInterfaceAddress: Equatable {
    let name: String
    let address: String
    let isUp: Bool
}

enum ActiveVPNInterfaceDetector {
    static func activeInterfaceNames(in addresses: [VPNInterfaceAddress]) -> Set<String> {
        Set(addresses.compactMap { entry in
            guard entry.isUp, isTunnelName(entry.name), isRoutableAddress(entry.address) else {
                return nil
            }
            return entry.name
        })
    }

    private static func isTunnelName(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("ppp") || name.hasPrefix("tun")
    }

    static func isRoutableAddress(_ address: String) -> Bool {
        let lower = address.lowercased()
        guard !lower.isEmpty,
              lower != "0.0.0.0",
              lower != "::",
              lower != "::1",
              !lower.hasPrefix("127."),
              !lower.hasPrefix("169.254."),
              !lower.hasPrefix("fe80:") else {
            return false
        }
        return PublicIPAddressParser.parse(address) != nil
    }
}

enum ProcessTrafficSamplingPolicy {
    static let refreshInterval: TimeInterval = 2

    static func shouldRun(panelOpen: Bool) -> Bool {
        panelOpen
    }
}

extension NetworkManager: InterfaceTrafficSampling, ProcessTrafficSampling, VPNInterfaceProviding {}
