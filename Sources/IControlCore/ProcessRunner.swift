import Foundation
import Darwin

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    public init() {}

    public func cancel() {
        lock.lock(); cancelled = true; let active = process; lock.unlock()
        if active?.isRunning == true { active?.terminate() }
    }

    public func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw ControlError("操作已取消") }
    }

    fileprivate func register(_ process: Process?) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw ControlError("操作已取消") }
        self.process = process
    }
}

public struct ProcessResult: Sendable {
    public let status: Int32
    public let output: Data
    public let errors: Data
    public var outputText: String { String(decoding: output, as: UTF8.self) }
    public var errorText: String { String(decoding: errors, as: UTF8.self) }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        let available = max(0, 2 * 1024 * 1024 - data.count)
        data.append(bytes.prefix(available))
    }
    func result() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

public enum ProcessRunner {
    /// Runs only on a worker queue. The input and output pipes are drained in
    /// parallel, so a large package upload cannot deadlock on stderr output.
    public static func run(executable: URL, arguments: [String], environment: [String: String]? = nil,
                           input: Data = Data(), timeout: TimeInterval = 30,
                           cancellation: CancellationToken? = nil,
                           onOutput: (@Sendable (String) -> Void)? = nil) throws -> ProcessResult {
        try cancellation?.check()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        do { try cancellation?.register(process) } catch { process.terminate(); throw error }
        defer { try? cancellation?.register(nil) }
        let readers = DispatchGroup()
        let output = OutputBuffer(), errors = OutputBuffer()
        for (pipe, buffer, report) in [(stdout, output, true), (stderr, errors, false)] {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { try? pipe.fileHandleForReading.close(); readers.leave() }
                while true {
                    let bytes = pipe.fileHandleForReading.availableData
                    if bytes.isEmpty { break }
                    buffer.append(bytes)
                    if report { onOutput?(String(decoding: bytes, as: UTF8.self)) }
                }
            }
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? stdin.fileHandleForWriting.close(); readers.leave() }
            do { if !input.isEmpty { try stdin.fileHandleForWriting.write(contentsOf: input) } } catch { }
        }
        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                // This PID was created by this invocation; unrelated processes
                // and services are never discovered or terminated.
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
        }
        process.waitUntilExit()
        readers.wait()
        try cancellation?.check()
        if timedOut { throw ControlError("设备操作超时。请检查 USB 连接，再重新检测环境。") }
        return ProcessResult(status: process.terminationStatus, output: output.result(), errors: errors.result())
    }
}

public func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
