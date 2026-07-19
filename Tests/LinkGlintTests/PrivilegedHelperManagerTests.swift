import XCTest
@testable import LinkGlint

final class PrivilegedHelperManagerTests: XCTestCase {
    func testConfigurationCacheExpiresUsingMonotonicUptime() {
        var uptime: TimeInterval = 100
        var resolutionCount = 0
        let manager = PrivilegedHelperManager(
            configurationCacheLifetime: 30,
            systemUptime: { uptime },
            configurationResolver: {
                resolutionCount += 1
                return resolutionCount == 1 ? "/cached-helper" : nil
            }
        )

        XCTAssertEqual(manager.state, .ready)
        XCTAssertEqual(resolutionCount, 1)

        uptime = 129.999
        XCTAssertEqual(manager.state, .ready)
        XCTAssertEqual(resolutionCount, 1)

        uptime = 130
        XCTAssertNotEqual(manager.state, .ready)
        XCTAssertEqual(resolutionCount, 2)
    }

    func testInvalidationDuringResolutionDiscardsStaleResult() {
        let resolverStarted = expectation(description: "resolver started")
        let stateResolved = expectation(description: "state resolved")
        let releaseFirstResolution = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var resolutionCount = 0
        var resolvedState: PrivilegedAccessState?

        let manager = PrivilegedHelperManager(configurationResolver: {
            resultLock.lock()
            resolutionCount += 1
            let currentResolution = resolutionCount
            resultLock.unlock()

            if currentResolution == 1 {
                resolverStarted.fulfill()
                releaseFirstResolution.wait()
                return "/stale-helper"
            }
            return nil
        })

        DispatchQueue.global(qos: .userInitiated).async {
            let state = manager.state
            resultLock.lock()
            resolvedState = state
            resultLock.unlock()
            stateResolved.fulfill()
        }

        wait(for: [resolverStarted], timeout: 2)
        manager.invalidateConfigurationCache()
        releaseFirstResolution.signal()
        wait(for: [stateResolved], timeout: 2)

        resultLock.lock()
        let finalState = resolvedState
        let finalResolutionCount = resolutionCount
        resultLock.unlock()
        XCTAssertNotEqual(finalState, .ready)
        XCTAssertEqual(finalResolutionCount, 2)

        // The post-invalidation resolution, including its nil result, is cached.
        XCTAssertNotEqual(manager.state, .ready)
        resultLock.lock()
        let cachedResolutionCount = resolutionCount
        resultLock.unlock()
        XCTAssertEqual(cachedResolutionCount, 2)
    }

    func testConcurrentCacheMissesShareOneResolution() {
        let resolverStarted = expectation(description: "resolver started")
        let allStatesResolved = expectation(description: "all states resolved")
        let releaseResolver = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var resolutionCount = 0
        var states: [PrivilegedAccessState] = []
        let callerCount = 8

        let manager = PrivilegedHelperManager(configurationResolver: {
            lock.lock()
            resolutionCount += 1
            let isFirst = resolutionCount == 1
            lock.unlock()
            if isFirst {
                resolverStarted.fulfill()
                _ = releaseResolver.wait(timeout: .now() + 2)
            }
            return "/configured-helper"
        })

        let group = DispatchGroup()
        for _ in 0..<callerCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let state = manager.state
                lock.lock()
                states.append(state)
                lock.unlock()
                group.leave()
            }
        }
        wait(for: [resolverStarted], timeout: 2)
        releaseResolver.signal()
        DispatchQueue.global().async {
            group.wait()
            allStatesResolved.fulfill()
        }
        wait(for: [allStatesResolved], timeout: 2)

        lock.lock()
        let finalResolutionCount = resolutionCount
        let finalStates = states
        lock.unlock()
        XCTAssertEqual(finalResolutionCount, 1)
        XCTAssertEqual(finalStates.count, callerCount)
        XCTAssertTrue(finalStates.allSatisfy { $0 == .ready })
    }
}
