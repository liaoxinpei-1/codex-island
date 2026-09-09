import Foundation

public struct RemoteHost: Equatable, Sendable {
    public let id: String
    public let name: String
    public let online: Bool
    public init(id: String, name: String, online: Bool) {
        self.id = id; self.name = name; self.online = online
    }
}

public struct OnlineCatalogUpdate: Sendable {
    public let accountID: String
    public var hosts: [RemoteHost]?
    public var cloudTasks: [IslandTask]?
    public var fetchedAt: Date
    public init(accountID: String, hosts: [RemoteHost]?, cloudTasks: [IslandTask]?, fetchedAt: Date = Date()) {
        self.accountID = accountID; self.hosts = hosts; self.cloudTasks = cloudTasks; self.fetchedAt = fetchedAt
    }
}

public enum CatalogMetadata {
    public enum ReadError: Error { case schema }
    public static func title(_ value: String?) -> String {
        let line = value?.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return line.isEmpty ? "未命名任务" : String(line.prefix(140))
    }
    public static func timestamp(_ value: Double) -> Double { value > 100_000_000_000 ? value / 1000 : value }
    public static func date(_ value: String?) -> Double {
        guard let value else { return 0 }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)?.timeIntervalSince1970 ?? 0
    }
    public static func hosts(_ response: JSONValue) throws -> [RemoteHost] {
        guard let items = response["items"]?.array else { throw ReadError.schema }
        return items.compactMap { item in
            guard let id = item["env_id"]?.string, !id.isEmpty else { return nil }
            let name = ["display_name", "name", "host_name"].compactMap { item[$0]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "远程 · \(id.suffix(8))"
            return RemoteHost(id: "remote-control:" + id, name: String(name.prefix(100)), online: item["online"]?.bool == true)
        }
    }
    public static func cloudTasks(_ response: JSONValue) throws -> [IslandTask] {
        guard let items = response["items"]?.array else { throw ReadError.schema }
        return items.compactMap { item in
            guard let id = item["id"]?.string,
                  id.range(of: #"^task_[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
                  item["archived"]?.bool != true else { return nil }
            let display = item["task_status_display"]
            let unread = item["has_unread_turn"]?.bool == true
            var task = IslandTask(id: id, title: title(item["title"]?.string), cwd: display?["environment_label"]?.string ?? "",
                                  updatedAt: timestamp(item["updated_at"]?.double ?? item["created_at"]?.double ?? 0),
                                  hasUnreadContent: unread, source: .codexCloud)
            task.evidence = .cloudQuery
            switch display?["latest_turn_status_display"]?["turn_status"]?.string {
            case "pending": task.phase = .running; task.statusNote = "云端排队中"
            case "in_progress": task.phase = .running
            case "completed": task.phase = unread ? .completed : .idle; task.statusNote = unread ? nil : "已完成"
            case "failed", "error": task.phase = .failed
            case "cancelled", "interrupted": task.phase = .idle; task.statusNote = "已取消"
            default: task.statusNote = unread ? "有新内容 · 状态未知" : "云端状态未知"
            }
            return task
        }.sorted(by: IslandTask.precedes)
    }
}

/// Decodes only task metadata. Unrelated settings, drafts, enrollment data and credentials are skipped.
public struct DesktopTaskCatalog {
    public var remoteTasks: [IslandTask] = []
    private var chatAccounts: [String: ChatAccount] = [:]

    private static let accountKey = CodingUserInfoKey(rawValue: "catalogAccountID")!
    public init(codexHome: URL, accountID: String? = nil, limitPerHost: Int = 24) throws {
        let url = codexHome.appendingPathComponent(".codex-global-state.json")
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1024 * 1024 else { throw CatalogMetadata.ReadError.schema }
        let decoder = JSONDecoder()
        if let accountID { decoder.userInfo[Self.accountKey] = accountID }
        let envelope = try decoder.decode(Envelope.self, from: Data(contentsOf: url))
        for (hostID, summaries) in envelope.atoms.remote {
            let name = envelope.connections.first { $0.hostId == hostID }?.displayName
            remoteTasks += summaries.filter { $0.hostId == hostID && UUID(uuidString: $0.conversationId) != nil }
                .sorted { $0.updatedAt > $1.updatedAt }.prefix(max(0, limitPerHost)).map {
                    var task = IslandTask(id: $0.conversationId, title: CatalogMetadata.title($0.title), cwd: $0.cwd ?? "",
                               updatedAt: CatalogMetadata.timestamp($0.updatedAt),
                               source: .remote(hostID: hostID, name: name), statusNote: "状态未同步")
                    task.activityHint = $0.threadRuntimeStatus?.type == "active" ? .active : $0.hasUnreadTurn == true ? .unread : nil
                    if task.activityHint != nil { task.evidence = .cachedHint; task.statusNote = "状态待同步 · 仅有缓存线索" }
                    return task
                }
        }
        chatAccounts = envelope.atoms.chatAccounts
    }
    public func chatTasks(accountID: String, limit: Int = 24) -> [IslandTask] {
        guard let account = chatAccounts[accountID] else { return [] }
        var tasks: [String: IslandTask] = [:]
        for row in account.rows where UUID(uuidString: row.id) != nil {
            let task = IslandTask(id: row.id, title: CatalogMetadata.title(row.title), cwd: "",
                                  updatedAt: CatalogMetadata.date(row.updatedAt ?? row.createdAt),
                                  source: .chatGPT(isWork: row.isTask), statusNote: "缓存记录 · 无实时状态")
            if tasks[task.id] == nil || tasks[task.id]!.updatedAt < task.updatedAt { tasks[task.id] = task }
        }
        return Array(tasks.values.sorted(by: IslandTask.precedes).prefix(max(0, limit)))
    }

    private struct Summary: Decodable {
        var conversationId: String
        var hostId: String
        var title: String?
        var cwd: String?
        var updatedAt: Double
        var threadRuntimeStatus: RuntimeStatus?
        var hasUnreadTurn: Bool?
    }
    private struct RuntimeStatus: Decodable { var type: String }
    private struct Connection: Decodable { var hostId: String; var displayName: String? }
    private struct ChatRow: Decodable { var id: String; var title: String?; var createdAt: String?; var updatedAt: String?; var isTask: Bool }
    private struct ChatPage: Decodable { var items: [ChatRow] }
    private struct PinnedChat: Decodable { var conversation: ChatRow }
    private struct ChatAccount: Decodable {
        var conversations: [ChatPage]?
        var flatConversations: [ChatPage]?
        var flatTasks: [ChatPage]?
        var tasks: [ChatPage]?
        var pinnedConversations: [PinnedChat]?
        var rows: [ChatRow] {
            ((conversations ?? []) + (flatConversations ?? []) + (flatTasks ?? []) + (tasks ?? [])).flatMap(\.items)
            + (pinnedConversations ?? []).map(\.conversation)
        }
    }
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private struct Atoms: Decodable {
        var remote: [String: [Summary]] = [:]
        var chatAccounts: [String: ChatAccount] = [:]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            let prefix = "remote-thread-summaries-v3:"
            for key in c.allKeys where key.stringValue.hasPrefix(prefix) {
                let host = String(key.stringValue.dropFirst(prefix.count))
                guard !host.isEmpty, host != "local" else { continue }
                remote[host] = try? c.decode([Summary].self, forKey: key)
            }
            if let accountID = decoder.userInfo[DesktopTaskCatalog.accountKey] as? String,
               let accounts = try? c.nestedContainer(keyedBy: Key.self, forKey: Key("chatgpt-sidebar-state-v1")),
               let account = try? accounts.decode(ChatAccount.self, forKey: Key(accountID)) {
                chatAccounts[accountID] = account
            }
        }
    }
    private struct Envelope: Decodable {
        var atoms: Atoms
        var connections: [Connection]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            atoms = try c.decode(Atoms.self, forKey: Key("electron-persisted-atom-state"))
            connections = (try? c.decode([Connection].self, forKey: Key("codex-managed-remote-connections"))) ?? []
        }
    }
}
