import Foundation

/// Runs a short-lived helper program and reads what it prints.
enum ProcessOutput {
    /// What the program printed to standard output, or nil when it couldn't be started or didn't end within `timeout` seconds (it is
    /// ended, killed if it ignores that). Blocks: call it off the main thread. The output is read while the program runs, so a program
    /// that prints more than a pipe holds doesn't wait for a reader that is waiting for it.
    nonisolated static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let reader = pipe.fileHandleForReading
        let collected = Collected()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global().async {
            collected.data = reader.readDataToEndOfFile()
            drained.leave()
        }
        let pid = process.processIdentifier
        let timedOut = Flag()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
            // A program that ignores the request is killed a moment later.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { if process.isRunning { kill(pid, SIGKILL) } }
        }
        process.waitUntilExit()
        // A child the program left running can hold the pipe open past its end.
        guard drained.wait(timeout: .now() + 1) == .success else { return nil }
        return timedOut.isSet ? nil : String(data: collected.data, encoding: .utf8)
    }

    private final class Collected: @unchecked Sendable { var data = Data() }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}
