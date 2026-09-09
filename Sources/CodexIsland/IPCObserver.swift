import Foundation
import Darwin
import IslandCore

struct SourceCoverage: Equatable {
    var catalog = 0
    var snapshots = 0
    var pending = 0
    var retries = 0
    var expirations = 0
    var firstSnapshotDelayMax: Double?
    var reasons: [String: Int] = [:]
    var diagnostic: [String: Any] {
        var value: [String: Any] = ["catalog": catalog, "currentSnapshots": snapshots, "pending": pending,
                                  "retries": retries, "expirations": expirations, "reasons": reasons]
        if let firstSnapshotDelayMax { value["firstSnapshotDelayMaxSeconds"] = firstSnapshotDelayMax }
        return value
    }
}

struct BridgeUpdate {
    var tasks: [IslandTask] = []
    var connected = false
    var liveCount = 0
    var message = "正在连接 Codex…"
    var catalogAvailable = true
    var coverage: [String: SourceCoverage] = [:]
}

/// Version-gated, read-only adapter for the desktop client's local IPC transport.
/// Allowed outbound messages: initialize, follow/unfollow, decline request handling.
final class IPCObserver {
    static let supportedSnapshotVersion = 11
    private let home: URL
    private let heartbeatInterval: TimeInterval
    private let snapshotTimeout: TimeInterval
    private let recoveryDelays: [TimeInterval]
    private let callback: (BridgeUpdate) -> Void
    private let lock = NSLock()
    private var stopped = false
    private var thread: Thread?
    private var fd: Int32 = -1
    private var clientID = ""
    private var catalog: [IslandTask] = []
    private var live: [String: LiveTaskState] = [:]
    private var owners: [String: String] = [:]
    private var subscribed: [String: IslandTask] = [:]
    private var catalogAvailable = false
    private var lastCatalog = Date.distantPast
    private var lastPublish = Date.distantPast
    private var lastResnapshot: [String: Date] = [:]
    private var snapshotDeadlines: [String: Date] = [:]
    private var archivedIDs = Set<String>()
    private struct Recovery {
        var requestedAt = Date()
        var firstSnapshotDelay: Double?
        var nextRetry: Date?
        var retries = 0
        var expirations = 0
        var reason: String?
        var activityHint: TaskActivityHint?
        var gapRequested = false
    }
    private var recovery: [String: Recovery] = [:]
    private var connectionMessage = "正在连接 Codex…"

    init(home: URL, heartbeatInterval: TimeInterval = 30, snapshotTimeout: TimeInterval = 10,
         recoveryDelays: [TimeInterval] = [2, 5, 10],
         callback: @escaping (BridgeUpdate) -> Void) {
        self.home = home; self.callback = callback
        self.heartbeatInterval = heartbeatInterval; self.snapshotTimeout = snapshotTimeout
        self.recoveryDelays = recoveryDelays
    }
    func start() {
        guard thread == nil else { return }
        thread = Thread { [weak self] in self?.run() }
        thread?.name = "Codex Island task observer"
        thread?.qualityOfService = .utility
        thread?.start()
    }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    private var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func run() {
        while !shouldStop {
            autoreleasepool {
                var failureReason = "connection_lost"
                do {
                    fd = try connectSocket()
                    try send(["type": "request", "requestId": UUID().uuidString, "method": "initialize",
                              "version": 0, "params": ["clientType": "codex-island"]])
                    try readLoop()
                } catch ObserverError.incompatible {
                    failureReason = "protocol_incompatible"
                    connectionMessage = "此 Codex 版本尚未兼容 · 可继续打开对话"
                } catch {
                    connectionMessage = "等待 Codex 客户端 · 正在重连"
                }
                if fd >= 0 { Darwin.close(fd); fd = -1 }
                for id in Array(live.keys) { invalidateLive(id, reason: failureReason) }
                owners.removeAll(); snapshotDeadlines.removeAll(); subscribed.removeAll(); clientID = ""
                refreshCatalog(); publish()
            }
            for _ in 0..<6 { if shouldStop { break }; Thread.sleep(forTimeInterval: 0.5) }
        }
    }

    private func connectSocket() throws -> Int32 {
        let path = home.appendingPathComponent("ipc/ipc.sock").path
        // Accept only a private socket and directory belonging to this macOS user.
        for (candidate, isDirectory) in [(home.appendingPathComponent("ipc").path, true), (path, false)] {
            var info = stat()
            guard lstat(candidate, &info) == 0, info.st_uid == getuid(),
                  (info.st_mode & S_IFMT) == (isDirectory ? S_IFDIR : S_IFSOCK),
                  info.st_mode & 0o022 == 0 else { throw ObserverError.unavailable }
        }
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw ObserverError.unavailable }
        var noSignal: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(socketFD); throw ObserverError.unavailable
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for i in bytes.indices { raw[i] = UInt8(bitPattern: bytes[i]) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { Darwin.close(socketFD); throw ObserverError.unavailable }
        return socketFD
    }

    private func readLoop() throws {
        var decoder = IPCFrameDecoder()
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        let connectedAt = Date()
        var lastHeartbeat = Date()
        while !shouldStop {
            if clientID.isEmpty && Date().timeIntervalSince(connectedAt) > 5 { throw ObserverError.unavailable }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            if ready < 0 { if errno == EINTR { continue }; throw ObserverError.unavailable }
            if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { throw ObserverError.unavailable }
            if ready > 0 {
                let count = Darwin.read(fd, &bytes, bytes.count)
                guard count > 0 else { throw ObserverError.unavailable }
                for frame in try decoder.append(Data(bytes.prefix(count))) {
                    let message = try JSONDecoder().decode(JSONValue.self, from: frame)
                    try receive(message)
                }
            }
            if !clientID.isEmpty {
                if Date().timeIntervalSince(lastCatalog) > 8 { refreshCatalog(); try updateSubscriptions() }
                // Periodically revalidate ownership/status so an idle former owner cannot remain "running" forever.
                if Date().timeIntervalSince(lastHeartbeat) > heartbeatInterval {
                    for id in live.keys where live[id]?.phase != .unknown || live[id]?.hasUnreadContent == true {
                        snapshotDeadlines[id] = Date().addingTimeInterval(snapshotTimeout)
                        try follow(id, following: true)
                    }
                    lastHeartbeat = Date()
                }
                // Keep priority rows stable while refresh replies are in flight; expire missing owners.
                for id in snapshotDeadlines.keys.filter({ snapshotDeadlines[$0]! < Date() }) {
                    invalidateLive(id, reason: "snapshot_timeout")
                    recovery[id]?.expirations += 1
                }
                let due = recovery.keys.filter { (live[$0] == nil || live[$0]?.phase == .unknown) && recovery[$0]?.nextRetry.map { $0 <= Date() } == true }.sorted().prefix(4)
                for id in due {
                    try follow(id, following: true)
                    recovery[id]!.retries += 1
                    let count = recovery[id]!.retries
                    recovery[id]!.nextRetry = count < recoveryDelays.count ? Date().addingTimeInterval(recoveryDelays[count]) : nil
                    if count >= recoveryDelays.count { recovery[id]!.reason = "retry_limit_reached" }
                }
            }
            if Date().timeIntervalSince(lastPublish) > 0.5 { publish() }
        }
        for id in subscribed.keys { try? follow(id, following: false) }
    }

    private func receive(_ message: JSONValue) throws {
        switch message["type"]?.string {
        case "response":
            if message["method"]?.string == "initialize", message["resultType"]?.string == "success",
               let id = message["result"]?["clientId"]?.string {
                clientID = id; connectionMessage = "已连接 Codex"
                refreshCatalog(); try updateSubscriptions(); publish()
            }
        case "client-discovery-request":
            if let id = message["requestId"]?.string {
                try send(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]])
            }
        case "broadcast":
            let params = message["params"]
            if message["method"]?.string == "client-status-changed", params?["status"]?.string == "disconnected",
               let owner = params?["clientId"]?.string {
                for id in owners.keys.filter({ owners[$0] == owner }) { invalidateLive(id, reason: "owner_disconnected") }
                return
            }
            guard let hostID = params?["hostId"]?.string, let threadID = params?["conversationId"]?.string else { return }
            let id = IslandTask.ipcIdentity(threadID: threadID, hostID: hostID)
            if message["method"]?.string == "thread-unarchived", message["version"]?.int == 1 {
                archivedIDs.remove(id); lastCatalog = .distantPast; return
            }
            guard subscribed[id] != nil else { return }
            if message["method"]?.string == "thread-archived", message["version"]?.int == 2 {
                archivedIDs.insert(id)
                live.removeValue(forKey: id); owners.removeValue(forKey: id)
                catalog.removeAll { $0.id == id }
                try updateSubscriptions(); publish(); return
            }
            if ["thread-stream-following-status-requested", "thread-read-state-changed"].contains(message["method"]?.string ?? "") {
                try follow(id, following: true); return
            }
            guard message["method"]?.string == "thread-stream-state-changed" else { return }
            guard message["version"]?.int == Self.supportedSnapshotVersion else { throw ObserverError.incompatible }
            guard let change = params?["change"] else { return }
            if let snapshot = LiveTaskState(change: change) {
                snapshotDeadlines.removeValue(forKey: id)
                live[id] = snapshot; owners[id] = message["sourceClientId"]?.string
                if recovery[id]?.firstSnapshotDelay == nil, let requestedAt = recovery[id]?.requestedAt {
                    recovery[id]?.firstSnapshotDelay = Date().timeIntervalSince(requestedAt)
                }
                recovery[id]?.nextRetry = nil; recovery[id]?.reason = nil
                if snapshot.phase == .unknown && !snapshot.hasUnreadContent {
                    if recovery[id]?.activityHint != nil { recovery[id]?.reason = "state_unavailable" }
                    if let record = recovery[id], record.activityHint != nil, record.retries < recoveryDelays.count {
                        recovery[id]?.nextRetry = Date().addingTimeInterval(recoveryDelays[record.retries])
                    }
                } else { recovery[id]?.activityHint = nil }
                recovery[id]?.gapRequested = false
            } else if change["type"]?.string == "patches" {
                guard owners[id] == nil || owners[id] == message["sourceClientId"]?.string else { return }
                if var state = live[id], state.apply(change: change) {
                    // A continuous update also confirms this stream is alive during a heartbeat refresh.
                    snapshotDeadlines.removeValue(forKey: id)
                    live[id] = state
                    if state.phase != .unknown || state.hasUnreadContent {
                        recovery[id]?.nextRetry = nil; recovery[id]?.activityHint = nil; recovery[id]?.reason = nil
                    }
                }
                else {
                    let needsSnapshot = recovery[id]?.gapRequested != true
                    invalidateLive(id, reason: "revision_gap")
                    recovery[id]?.gapRequested = true
                    if needsSnapshot && Date().timeIntervalSince(lastResnapshot[id] ?? .distantPast) > 2 {
                        lastResnapshot[id] = Date(); try follow(id, following: true)
                    }
                }
            }
        default: break
        }
    }

    private func invalidateLive(_ id: String, reason: String) {
        let previous = live.removeValue(forKey: id)
        owners.removeValue(forKey: id); snapshotDeadlines.removeValue(forKey: id)
        if let previous, let index = catalog.firstIndex(where: { $0.id == id }) {
            if [.running, .waiting, .failed].contains(previous.phase) { catalog[index].activityHint = .active }
            else if previous.hasUnreadContent || previous.phase == .completed { catalog[index].activityHint = .unread }
            recovery[id]?.activityHint = catalog[index].activityHint
            // A new loss after confirmed state starts one bounded recovery episode.
            recovery[id]?.retries = 0
            if catalog[index].activityHint != nil { recovery[id]?.nextRetry = recoveryDelays.first.map { Date().addingTimeInterval($0) } }
        }
        if previous == nil && reason == "revision_gap" && recovery[id]?.gapRequested != true && recovery[id]?.retries == 0 {
            recovery[id]?.nextRetry = recoveryDelays.first.map { Date().addingTimeInterval($0) }
        }
        recovery[id]?.reason = reason
    }

    private func refreshCatalog() {
        lastCatalog = Date()
        let local = try? TaskCatalog(codexHome: home).read()
        let remote = try? DesktopTaskCatalog(codexHome: home).remoteTasks
        if local != nil || remote != nil {
            let recent = ((local ?? catalog.filter { $0.source == .local }) + (remote ?? catalog.filter { $0.source.hostID != "local" }))
                .filter { !archivedIDs.contains($0.id) }
            // Keep active, waiting, and unread work visible outside the recent catalog page.
            let ids = Set(recent.map(\.id))
            let retained = catalog.filter {
                guard !ids.contains($0.id), let state = live[$0.id] else { return false }
                return state.hasUnreadContent || [.running, .waiting, .failed, .completed].contains(state.phase)
            }
            catalog = recent + retained.prefix(12); catalogAvailable = true
        } else { catalogAvailable = false }
    }

    private func updateSubscriptions() throws {
        let desired = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in Set(subscribed.keys).subtracting(desired.keys) {
            try follow(id, following: false); live.removeValue(forKey: id); owners.removeValue(forKey: id); snapshotDeadlines.removeValue(forKey: id)
            recovery.removeValue(forKey: id); lastResnapshot.removeValue(forKey: id)
        }
        let added = Set(desired.keys).subtracting(subscribed.keys)
        recovery = recovery.filter { desired[$0.key] != nil }
        subscribed = desired
        for id in added {
            let hint = recovery[id]?.activityHint ?? desired[id]?.activityHint
            recovery[id] = Recovery(nextRetry: hint == nil ? nil : recoveryDelays.first.map { Date().addingTimeInterval($0) }, activityHint: hint)
            try follow(id, following: true)
        }
        // A newly appearing hint can trigger recovery; an unchanged cache cannot restart an exhausted loop.
        for id in desired.keys where !added.contains(id) && (live[id] == nil || (live[id]?.phase == .unknown && live[id]?.hasUnreadContent != true)) && recovery[id]?.retries == 0 && recovery[id]?.nextRetry == nil {
            if desired[id]?.activityHint != nil {
                recovery[id]?.activityHint = desired[id]?.activityHint
                recovery[id]?.nextRetry = recoveryDelays.first.map { Date().addingTimeInterval($0) }
            }
        }
    }
    private func follow(_ id: String, following: Bool) throws {
        guard !clientID.isEmpty, let task = subscribed[id], let hostID = task.source.hostID else { return }
        try send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
                  "sourceClientId": clientID,
                  "params": ["conversationId": task.threadID, "hostId": hostID, "following": following]])
    }
    private func send(_ object: [String: Any]) throws {
        let data = IPCFrameDecoder.encode(try JSONSerialization.data(withJSONObject: object))
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ObserverError.unavailable }
                offset += count
            }
        }
    }
    private func publish() {
        lastPublish = Date()
        var tasks: [IslandTask] = catalog.map { task -> IslandTask in
            var task = task
            if let state = live[task.id] {
                task.evidence = .ipc
                task.activityHint = state.phase == .unknown && !state.hasUnreadContent ? (recovery[task.id]?.activityHint ?? task.activityHint) : nil
                task.statusNote = nil
                task.phase = state.phase
                task.hasUnreadContent = state.hasUnreadContent
                if let activityAt = state.activityAt { task.updatedAt = max(task.updatedAt, activityAt) }
                if let title = state.title, !title.isEmpty { task.title = title }
                if task.hasPendingActivity { task.statusNote = "状态待同步 · 宿主尚未提供有效状态" }
            } else {
                task.activityHint = recovery[task.id]?.activityHint ?? task.activityHint
                let evidence = task.evidence
                task.invalidateStatus(task.activityHint == nil ? (task.source == .local ? "最近任务" : "状态未同步") : "状态待同步 · 未确认当前活动")
                task.evidence = recovery[task.id]?.firstSnapshotDelay == nil ? evidence : .expired
            }
            return task
        }
        tasks.sort(by: IslandTask.precedes)
        var coverage: [String: SourceCoverage] = [:]
        for task in tasks {
            guard let host = task.source.hostID else { continue }
            var source = coverage[host] ?? SourceCoverage()
            source.catalog += 1
            if task.evidence == .ipc { source.snapshots += 1 }
            if task.hasPendingActivity { source.pending += 1 }
            if let record = recovery[task.id] {
                source.retries += record.retries; source.expirations += record.expirations
                if let delay = record.firstSnapshotDelay { source.firstSnapshotDelayMax = max(source.firstSnapshotDelayMax ?? 0, delay) }
                if let reason = record.reason { source.reasons[reason, default: 0] += 1 }
            }
            coverage[host] = source
        }
        callback(BridgeUpdate(tasks: tasks, connected: !clientID.isEmpty, liveCount: live.count,
                              message: connectionMessage, catalogAvailable: catalogAvailable, coverage: coverage))
    }
    private enum ObserverError: Error { case unavailable, incompatible }
}
