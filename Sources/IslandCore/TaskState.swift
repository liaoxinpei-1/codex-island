import Foundation

public enum TaskPhase: String, Codable {
    case running, waiting, completed, idle, failed, unknown
    public var label: String {
        switch self {
        case .running: return "运行中"
        case .waiting: return "等待你的确认"
        case .completed: return "已完成 · 待查看"
        case .idle: return "就绪"
        case .failed: return "出现错误"
        case .unknown: return "最近任务"
        }
    }
    public var priority: Int {
        switch self {
        case .waiting: return 0
        case .failed: return 1
        case .running: return 2
        case .completed: return 3
        case .idle: return 4
        case .unknown: return 5
        }
    }
}

public struct IslandTask: Identifiable, Equatable {
    public let id: String
    public var title: String
    public var cwd: String
    public var updatedAt: Double
    public var phase: TaskPhase
    public var hasUnreadContent: Bool
    public init(id: String, title: String, cwd: String, updatedAt: Double, phase: TaskPhase = .unknown, hasUnreadContent: Bool = false) {
        self.id = id; self.title = title; self.cwd = cwd; self.updatedAt = updatedAt; self.phase = phase
        self.hasUnreadContent = hasUnreadContent
    }
    public var projectName: String { URL(fileURLWithPath: cwd).lastPathComponent }
    public var section: TaskSection {
        switch phase {
        case .waiting, .failed: return .attention
        case .running: return .running
        case .completed: return .updates
        default: return hasUnreadContent ? .updates : .recent
        }
    }
    public var displayStatus: String {
        hasUnreadContent && [.unknown, .idle].contains(phase) ? "有新内容 · 待查看" : phase.label
    }
    public static func precedes(_ left: IslandTask, _ right: IslandTask) -> Bool {
        if left.section != right.section { return left.section.rawValue < right.section.rawValue }
        if left.section == .attention && left.phase != right.phase { return left.phase.priority < right.phase.priority }
        if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
        return left.id < right.id
    }
}

public enum TaskSection: Int {
    case attention, running, updates, recent
}

public enum JSONValue: Codable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue? {
        if case .object(let value) = self { return value[key] }
        return nil
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var int: Int? { if case .number(let v) = self, v.isFinite, abs(v) < 9e15 { return Int(v) }; return nil }
    public var double: Double? { if case .number(let v) = self, v.isFinite { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }

    public mutating func patch(path: ArraySlice<JSONValue>, value: JSONValue?, remove: Bool) -> Bool {
        guard let head = path.first else { self = remove ? .null : value ?? .null; return true }
        switch self {
        case .object(var object):
            guard let key = head.string else { return false }
            if path.count == 1 {
                if remove { object.removeValue(forKey: key) } else { object[key] = value ?? .null }
            } else {
                guard var child = object[key], child.patch(path: path.dropFirst(), value: value, remove: remove) else { return false }
                object[key] = child
            }
            self = .object(object); return true
        case .array(var array):
            guard let index = head.int ?? head.string.flatMap(Int.init), index >= 0 else { return false }
            if path.count == 1 {
                if remove { guard index < array.count else { return false }; array.remove(at: index) }
                else if index == array.count { array.append(value ?? .null) }
                else { guard index < array.count else { return false }; array[index] = value ?? .null }
            } else {
                guard index < array.count else { return false }
                guard array[index].patch(path: path.dropFirst(), value: value, remove: remove) else { return false }
            }
            self = .array(array); return true
        default: return false
        }
    }
}

/// Retains task metadata only. Chat messages, tool output, and permissions are discarded.
public struct LiveTaskState {
    public private(set) var revision: Int
    public private(set) var document: JSONValue
    private static let allowed = Set(["threadRuntimeStatus", "hasUnreadTurn", "unreadMessageCount", "updatedAt", "recencyAt", "title", "generatedTitle"])
    public init?(change: JSONValue) {
        guard change["type"]?.string == "snapshot", let revision = change["revision"]?.int,
              case .object(let state) = change["conversationState"] else { return nil }
        self.revision = revision
        self.document = .object(state.filter { Self.allowed.contains($0.key) })
    }
    public mutating func apply(change: JSONValue) -> Bool {
        guard change["type"]?.string == "patches", change["baseRevision"]?.int == revision,
              let next = change["revision"]?.int, next >= revision,
              let patches = change["patches"]?.array else { return false }
        var copy = document
        for patch in patches {
            guard let path = patch["path"]?.array, let first = path.first?.string,
                  let op = patch["op"]?.string else { return false }
            guard Self.allowed.contains(first) else { continue }
            guard ["replace", "add", "remove"].contains(op),
                  copy.patch(path: path[...], value: patch["value"], remove: op == "remove") else { return false }
        }
        document = copy; revision = next; return true
    }
    public var title: String? { document["title"]?.string ?? document["generatedTitle"]?.string }
    public var hasUnreadContent: Bool {
        document["hasUnreadTurn"]?.bool == true || (document["unreadMessageCount"]?.int ?? 0) > 0
    }
    public var activityAt: Double? {
        ["updatedAt", "recencyAt"].compactMap { document[$0]?.double }
            .map { $0 > 100_000_000_000 ? $0 / 1000 : $0 }.max()
    }
    public var phase: TaskPhase {
        let status = document["threadRuntimeStatus"]
        switch status?["type"]?.string {
        case "active":
            let flags = status?["activeFlags"]?.array?.compactMap(\.string) ?? []
            return flags.contains(where: { ["waitingOnApproval", "waitingOnUserInput"].contains($0) }) ? .waiting : .running
        case "idle": return document["hasUnreadTurn"]?.bool == true ? .completed : .idle
        case "systemError": return .failed
        default: return .unknown
        }
    }
}

public enum CodexLink {
    public static func thread(_ id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return URL(string: "codex://threads/\(id)")
    }
    public static func newThread(prompt: String? = nil) -> URL {
        var c = URLComponents(string: "codex://threads/new")!
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            c.queryItems = [URLQueryItem(name: "prompt", value: prompt)]
        }
        return c.url!
    }
    public static let settings = URL(string: "codex://settings")!
}
