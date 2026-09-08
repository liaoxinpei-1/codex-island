import Foundation
import SQLite3

public struct TaskCatalog {
    public let codexHome: URL
    public init(codexHome: URL) { self.codexHome = codexHome }
    public func read(limit: Int = 24) throws -> [IslandTask] {
        let files = try FileManager.default.contentsOfDirectory(at: codexHome, includingPropertiesForKeys: nil)
        let databases = files.filter {
            $0.lastPathComponent.range(of: #"^state_\d+\.sqlite$"#, options: .regularExpression) != nil
        }.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        guard let path = databases.first else { throw CatalogError.unavailable }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; throw CatalogError.unavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 300)
        // Columns common to current supported desktop schemas; never repair or write the Codex DB.
        // The paginated history backend leaves has_user_event at zero for real user tasks.
        // A nonempty initial title distinguishes started tasks from empty internal helper sessions.
        let sql = "SELECT id, COALESCE(NULLIF(name, ''), title), cwd, updated_at FROM threads WHERE archived = 0 AND length(trim(title)) > 0 AND source IN ('vscode', 'cli', 'appServer') ORDER BY updated_at DESC LIMIT ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CatalogError.schema }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var result: [IslandTask] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String {
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            let id = text(0)
            guard UUID(uuidString: id) != nil else { continue }
            let title = String(text(1).split(whereSeparator: \.isNewline).first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(IslandTask(id: id, title: title.isEmpty ? "未命名任务" : String(title.prefix(140)),
                                     cwd: text(2), updatedAt: sqlite3_column_double(statement, 3)))
        }
        return result
    }
    enum CatalogError: Error { case unavailable, schema }
}
