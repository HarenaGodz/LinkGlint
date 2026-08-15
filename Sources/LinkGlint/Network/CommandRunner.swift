import Foundation
import Darwin

enum FirstSuccessRace {
    /// Runs producers in order and returns the first non-nil result.
    /// Sequential short-timeout probes avoid nested GCD waits on the global pool.
    static func first<T>(_ producers: [() -> T?]) -> T? {
        for producer in producers {
            if let value = producer() {
                return value
            }
        }
        return nil
    }

    /// Runs producers concurrently and returns the first non-nil result.
    static func parallelFirst<T>(_ producers: [() -> T?]) -> T? {
        guard !producers.isEmpty else { return nil }
        if producers.count == 1 { return producers[0]() }

        let lock = NSLock()
        var result: T?
        let group = DispatchGroup()

        for producer in producers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                guard let value = producer() else { return }
                lock.lock()
                if result == nil { result = value }
                lock.unlock()
            }
        }

        while true {
            lock.lock()
            let current = result
            lock.unlock()
            if current != nil { return current }
            switch group.wait(timeout: .now() + 0.01) {
            case .success:
                return result
            case .timedOut:
                continue
            }
        }
    }
}

enum CommandRunner {
    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: TimeInterval? = 20
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let stateLock = NSLock()
        var timedOut = false
        let timeoutWork: DispatchWorkItem?
        if let timeout {
            let work = DispatchWorkItem {
                stateLock.lock()
                defer { stateLock.unlock() }
                guard process.isRunning else { return }
                timedOut = true
                process.terminate()
                let processID = process.processIdentifier
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                    stateLock.lock()
                    defer { stateLock.unlock() }
                    if process.isRunning { kill(processID, SIGKILL) }
                }
            }
            timeoutWork = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(timeout, 0.1), execute: work)
        } else {
            timeoutWork = nil
        }
        // Drain the pipe while the child is running. Waiting first can deadlock
        // once output fills the kernel pipe buffer.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWork?.cancel()
        stateLock.lock()
        let didTimeOut = timedOut
        stateLock.unlock()
        let text = String(data: data, encoding: .utf8) ?? ""
        if didTimeOut {
            let executableName = URL(fileURLWithPath: executable).lastPathComponent
            throw NetworkError.commandFailed("命令 \(executableName) 执行超时，请稍后重试。")
        }
        guard process.terminationStatus == 0 else {
            let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let executableName = URL(fileURLWithPath: executable).lastPathComponent
            throw NetworkError.commandFailed(
                detail.isEmpty
                    ? "命令 \(executableName) 执行失败（状态 \(process.terminationStatus)）。"
                    : detail
            )
        }
        return text
    }

}

