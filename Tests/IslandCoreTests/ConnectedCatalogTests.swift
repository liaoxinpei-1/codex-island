import Foundation
import XCTest
@testable import IslandCore

final class ConnectedCatalogTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

    func testRemoteCacheSeparatesHostsAndNeverReplaysCachedRunningStatus() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let id = UUID().uuidString
        let row: (String) -> [String: Any] = { host in
            ["conversationId": id, "hostId": host, "title": "Remote task", "cwd": "D:\\code\\project", "updatedAt": 1788874624000,
             "threadRuntimeStatus": ["type": "active"], "hasUnreadTurn": true]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "electron-persisted-atom-state": ["remote-thread-summaries-v3:ssh:build": [row("ssh:build")],
                                               "remote-thread-summaries-v3:remote-control:env": [row("remote-control:env")],
                                               "remote-thread-summaries-v4:future": [row("future")]],
            "codex-managed-remote-connections": [["hostId": "ssh:build", "displayName": "Build Mac"]]
        ])
        try data.write(to: home.appendingPathComponent(".codex-global-state.json"))
        let tasks = try DesktopTaskCatalog(codexHome: home).remoteTasks
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(Set(tasks.map(\.id)).count, 2)
        XCTAssertEqual(Set(tasks.map(\.threadID)), [id])
        XCTAssertTrue(tasks.allSatisfy { $0.phase == .unknown && !$0.hasUnreadContent && $0.section == .recent })
        XCTAssertTrue(tasks.allSatisfy { $0.projectName == "project" && $0.updatedAt == 1788874624 })
        XCTAssertEqual(tasks.first { $0.source.hostID == "ssh:build" }?.source.label, "Build Mac")
    }

    func testChatCacheReadsOnlyRequestedAccountAndDeduplicatesPinnedRows() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let id = UUID().uuidString
        let row: [String: Any] = ["id": id, "title": "Cloud work", "isTask": true, "updatedAt": "2026-09-09T01:02:03.123Z"]
        let data = try JSONSerialization.data(withJSONObject: ["electron-persisted-atom-state": ["chatgpt-sidebar-state-v1": [
            "account-a": ["pinnedConversations": [["conversation": row]], "flatTasks": [["items": [row]]]],
            "account-b": "malformed data from a different account must not be decoded"
        ]]])
        try data.write(to: home.appendingPathComponent(".codex-global-state.json"))
        let catalog = try DesktopTaskCatalog(codexHome: home, accountID: "account-a")
        XCTAssertEqual(catalog.chatTasks(accountID: "account-a").count, 1)
        XCTAssertEqual(catalog.chatTasks(accountID: "account-a").first?.source, .chatGPT(isWork: true))
        XCTAssertEqual(catalog.chatTasks(accountID: "account-a").first?.phase, .unknown)
        XCTAssertTrue(catalog.chatTasks(accountID: "account-b").isEmpty)
        XCTAssertTrue(try DesktopTaskCatalog(codexHome: home).chatTasks(accountID: "account-a").isEmpty)
    }

    func testCloudCompletionRequiresUnreadEvidenceToEnterUpdates() throws {
        let response = try json(#"{"items":[{"id":"task_read","title":"Read","updated_at":1788874624,"has_unread_turn":false,"task_status_display":{"latest_turn_status_display":{"turn_status":"completed"}}},{"id":"task_unread","has_unread_turn":true,"task_status_display":{"latest_turn_status_display":{"turn_status":"completed"}}},{"id":"task_pending","task_status_display":{"latest_turn_status_display":{"turn_status":"pending"}}},{"id":"task_future","task_status_display":{"latest_turn_status_display":{"turn_status":"future_status"}}},{"id":"task_archived","archived":true},{"id":"../../settings"}]}"#)
        let tasks = try CatalogMetadata.cloudTasks(response)
        XCTAssertEqual(tasks.count, 4)
        XCTAssertEqual(tasks.first { $0.threadID == "task_read" }?.section, .recent)
        XCTAssertEqual(tasks.first { $0.threadID == "task_read" }?.displayStatus, "已完成")
        XCTAssertEqual(tasks.first { $0.threadID == "task_unread" }?.phase, .completed)
        XCTAssertEqual(tasks.first { $0.threadID == "task_pending" }?.phase, .running)
        XCTAssertEqual(tasks.first { $0.threadID == "task_future" }?.phase, .unknown)
        XCTAssertThrowsError(try CatalogMetadata.cloudTasks(json(#"{"unexpected":[]}"#)))
        XCTAssertTrue(try CatalogMetadata.cloudTasks(json(#"{"items":[]}"#)).isEmpty)
    }

    func testMachineNamesPreferClientDisplayNameAndKeepOfflineState() throws {
        let hosts = try CatalogMetadata.hosts(json(#"{"items":[{"env_id":"env_a","display_name":"Windows","host_name":"DESKTOP-123","online":true},{"env_id":"env_b","display_name":"  ","host_name":"Build Mac","online":false}]}"#))
        XCTAssertEqual(hosts, [RemoteHost(id: "remote-control:env_a", name: "Windows", online: true),
                               RemoteHost(id: "remote-control:env_b", name: "Build Mac", online: false)])
    }

    func testSourceSpecificLinksUseRawIDsAndNeverTrustRemoteURLs() {
        let id = UUID().uuidString
        let remote = IslandTask(id: id, title: "Task", cwd: "", updatedAt: 0, source: .remote(hostID: "ssh:build", name: "Build"))
        XCTAssertNotEqual(remote.id, remote.threadID)
        XCTAssertEqual(CodexLink.task(remote)?.absoluteString, "codex://threads/" + id)
        let cloud = IslandTask(id: "task_e_example", title: "Cloud", cwd: "", updatedAt: 0, source: .codexCloud)
        XCTAssertEqual(CodexLink.task(cloud)?.absoluteString, "https://chatgpt.com/codex/tasks/task_e_example")
        var chat = IslandTask(id: id, title: "Chat", cwd: "", updatedAt: 0, source: .chatGPT(isWork: false))
        XCTAssertEqual(CodexLink.task(chat)?.absoluteString, "https://chatgpt.com/c/" + id)
        chat.source = .codexCloud
        XCTAssertNil(CodexLink.task(chat))
    }
}
