import Foundation
import Darwin
import IslandCore

enum OnlineCatalogError: Error {
    case unavailable, authentication, missingCLI
    var message: String {
        switch self {
        case .authentication: return "请在 Codex 登录后查看云端任务和机器名称"
        case .missingCLI: return "未找到 Codex 云端读取程序"
        case .unavailable: return "云端查询暂不可用，稍后自动重试"
        }
    }
}

/// Fixed metadata GETs only. Credentials live for one fetch, with no persistent session, redirects or auth refresh.
final class OnlineCatalogReader: @unchecked Sendable {
    private let executable: URL?
    private let home: URL
    private let queue = DispatchQueue(label: "codex-island-online-catalog", qos: .utility)
    private let lock = NSLock()
    private var stopped = false
    private var fetching = false
    private var process: Process?
    private let session: URLSession

    init(executable: URL?, home: URL) {
        self.executable = executable; self.home = home
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    func refresh(_ completion: @escaping @Sendable (Result<OnlineCatalogUpdate, OnlineCatalogError>) -> Void) {
        lock.lock()
        guard !stopped, !fetching else { lock.unlock(); return }
        fetching = true; lock.unlock()
        queue.async { [self] in
            do {
                let credentials = try readCredentials()
                Task {
                    async let hosts = readHosts(credentials)
                    async let cloud = readCloud(credentials)
                    let update = await OnlineCatalogUpdate(accountID: credentials.accountID, hosts: hosts, cloudTasks: cloud)
                    finish(.success(update), completion)
                }
            } catch { finish(.failure(error as? OnlineCatalogError ?? .unavailable), completion) }
        }
    }
    func stop() {
        lock.lock(); stopped = true
        if let process, process.isRunning { Darwin.kill(process.processIdentifier, SIGTERM) }
        lock.unlock()
        session.invalidateAndCancel()
    }
    private func finish(_ result: Result<OnlineCatalogUpdate, OnlineCatalogError>,
                        _ completion: @Sendable (Result<OnlineCatalogUpdate, OnlineCatalogError>) -> Void) {
        lock.lock(); fetching = false; let deliver = !stopped; lock.unlock()
        if deliver { completion(result) }
    }
    private var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private struct Credentials { let token: String; let accountID: String }
    private func readHosts(_ credentials: Credentials) async -> [RemoteHost]? {
        do {
            var hosts: [RemoteHost] = []
            var cursor: String?
            for _ in 0..<5 {
                var query = [URLQueryItem(name: "limit", value: "100")]
                if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
                let value = try await get(path: "/codex/remote/control/environments", query: query, credentials: credentials)
                hosts += try CatalogMetadata.hosts(value)
                cursor = value["cursor"]?.string
                if cursor == nil || cursor == "" { return hosts }
            }
            return nil // An incomplete host list must not hide machines as if they had been removed.
        } catch { return nil }
    }
    private func readCloud(_ credentials: Credentials) async -> [IslandTask]? {
        do {
            let value = try await get(path: "/wham/tasks/list", query: [URLQueryItem(name: "limit", value: "20"),
                                       URLQueryItem(name: "task_filter", value: "current")], credentials: credentials)
            return try CatalogMetadata.cloudTasks(value)
        } catch { return nil }
    }
    private func get(path: String, query: [URLQueryItem], credentials: Credentials) async throws -> JSONValue {
        guard !cancelled, ["/codex/remote/control/environments", "/wham/tasks/list"].contains(path) else { throw OnlineCatalogError.unavailable }
        var components = URLComponents(string: "https://chatgpt.com/backend-api" + path)!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer " + credentials.token, forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        let (data, response) = try await session.data(for: request)
        guard !cancelled, (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4 * 1024 * 1024 else { throw OnlineCatalogError.unavailable }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func readCredentials() throws -> Credentials {
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else { throw OnlineCatalogError.missingCLI }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codex-island-metadata-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = executable
        child.arguments = ["app-server", "--listen", "stdio://"]
        child.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        child.environment = environment
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        lock.lock()
        guard !stopped else { lock.unlock(); throw OnlineCatalogError.unavailable }
        do { try child.run(); process = child; lock.unlock() }
        catch { lock.unlock(); throw OnlineCatalogError.unavailable }
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
            var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex-island-metadata", "version": "0.1.23"]]])
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        var buffer = Data(), bytes = [UInt8](repeating: 0, count: 65536)
        while !cancelled && ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 200)
            if ready < 0 { if errno == EINTR { continue }; throw OnlineCatalogError.unavailable }
            if ready == 0 { continue }
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw OnlineCatalogError.unavailable }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 2 * 1024 * 1024 else { throw OnlineCatalogError.unavailable }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(buffer.startIndex...newline)
                guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else { continue }
                if message["id"]?.int == 1 {
                    guard message["result"] != nil else { throw OnlineCatalogError.unavailable }
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "getAuthStatus", "params": ["includeToken": true, "refreshToken": false]])
                } else if message["id"]?.int == 2 {
                    guard let token = message["result"]?["authToken"]?.string,
                          let accountID = Self.accountID(token) else { throw OnlineCatalogError.authentication }
                    return Credentials(token: token, accountID: accountID)
                }
            }
        }
        throw OnlineCatalogError.unavailable
    }
    private static func accountID(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let claims = try? JSONDecoder().decode(JSONValue.self, from: data),
              let auth = claims["https://api.openai.com/auth"],
              let id = auth["chatgpt_account_id"]?.string ?? auth["account_id"]?.string, !id.isEmpty else { return nil }
        return id
    }
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
