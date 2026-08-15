import Foundation
import Darwin
import LinkGlintHelperSupport

private enum HelperMainError: Error, CustomStringConvertible {
    case permission

    var description: String { "LinkGlintHelper must run as root." }
}

private final class SystemHelperCommandExecutor: HelperCommandExecutor {
    func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let stateLock = NSLock()
        var timedOut = false
        let timeoutWork = DispatchWorkItem {
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
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWork
        )
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWork.cancel()
        stateLock.lock()
        let didTimeOut = timedOut
        stateLock.unlock()
        let output = String(data: data, encoding: .utf8) ?? ""
        if didTimeOut {
            throw HelperWorkflowError.command(
                "\(URL(fileURLWithPath: executable).lastPathComponent) timed out."
            )
        }
        guard process.terminationStatus == 0 else {
            throw HelperWorkflowError.command(
                output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output
    }
}

do {
    guard geteuid() == 0 else { throw HelperMainError.permission }
    let operation = try HelperRequest.parse(Array(CommandLine.arguments.dropFirst()))
    let workflow = HelperWorkflow(executor: SystemHelperCommandExecutor())
    if let output = try workflow.execute(operation) { print(output) }
} catch {
    FileHandle.standardError.write(Data("LinkGlintHelper: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
