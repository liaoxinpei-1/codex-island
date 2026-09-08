import Foundation
import Darwin
import IslandCore

enum UsageReadError: Error {
    case unavailable, timeout, authentication, missingCLI
    var message: String {
        switch self {
        case .authentication: return "请在 Codex 登录后查看额度"
        case .missingCLI: return "未找到 Codex 额度读取程序"
        case .timeout: return "额度读取超时，稍后自动重试"
        case .unavailable: return "额度暂不可用，稍后自动重试"
        }
    }
}

/// Public stdio RPC only; never sends thread, turn, login, purchase, or reset requests.
final class UsageReader: @unchecked Sendable {
    private let executable: URL?
    private let queue = DispatchQueue(label: "codex-island-usage", qos: .utility)
    private let lock = NSLock()
    private var stopped = false
    private var fetching = false
    private var process: Process?

    init(executable: URL?) { self.executable = executable }

    func refresh(_ completion: @escaping @Sendable (Result<UsageSnapshot, UsageReadError>) -> Void) {
        lock.lock()
        guard !stopped, !fetching else { lock.unlock(); return }
        fetching = true
        lock.unlock()
        queue.async { [self] in
            let result: Result<UsageSnapshot, UsageReadError>
            do { result = .success(try read()) }
            catch { result = .failure(error as? UsageReadError ?? .unavailable) }
            lock.lock()
            fetching = false
            let deliver = !stopped
            lock.unlock()
            if deliver { completion(result) }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        if let process, process.isRunning { Darwin.kill(process.processIdentifier, SIGTERM) }
        lock.unlock()
    }

    private var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func read() throws -> UsageSnapshot {
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else { throw UsageReadError.missingCLI }
        let child = Process()
        let input = Pipe(), output = Pipe()
        child.executableURL = executable
        child.arguments = ["app-server", "--listen", "stdio://"]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        // A helper that exits during the handshake must not send SIGPIPE to the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        lock.lock()
        guard !stopped else { lock.unlock(); throw UsageReadError.unavailable }
        do { try child.run(); process = child; lock.unlock() }
        catch { lock.unlock(); throw UsageReadError.unavailable }
        defer {
            try? input.fileHandleForWriting.close()
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
            try? output.fileHandleForReading.close()
            lock.lock(); process = nil; lock.unlock()
        }

        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex-island", "version": "0.1.22"]]])
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 65536)
        while !cancelled && ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 200)
            if ready < 0 { if errno == EINTR { continue }; throw UsageReadError.unavailable }
            if ready == 0 { continue }
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw UsageReadError.unavailable }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 2 * 1024 * 1024 else { throw UsageReadError.unavailable }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else { continue }
                if message["id"]?.int == 1 {
                    guard message["result"] != nil else { throw UsageReadError.unavailable }
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if message["id"]?.int == 2 {
                    if let detail = message["error"]?["message"]?.string?.lowercased(),
                       detail.contains("auth") || detail.contains("login") { throw UsageReadError.authentication }
                    guard let result = message["result"], let snapshot = UsageSnapshot(response: result) else { throw UsageReadError.unavailable }
                    return snapshot
                }
            }
        }
        throw UsageReadError.timeout
    }
}
