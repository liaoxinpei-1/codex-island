import AppKit
import SwiftUI
import XCTest
import IslandCore
@testable import CodexIsland

final class ConnectedPresentationTests: XCTestCase {
    @MainActor func testActiveCacheWithoutSnapshotsDoesNotReportGlobalReady() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let rows: [[String: Any]] = [
            ["conversationId": UUID().uuidString, "hostId": "ssh:build", "title": "Long task", "updatedAt": 1,
             "threadRuntimeStatus": ["type": "active"], "hasUnreadTurn": false],
            ["conversationId": UUID().uuidString, "hostId": "ssh:build", "title": "Recent task", "updatedAt": Date().timeIntervalSince1970,
             "threadRuntimeStatus": ["type": "active"], "hasUnreadTurn": true],
            ["conversationId": UUID().uuidString, "hostId": "ssh:build", "title": "History", "updatedAt": 1,
             "threadRuntimeStatus": ["type": "notLoaded"], "hasUnreadTurn": false]
        ]
        try JSONSerialization.data(withJSONObject: ["electron-persisted-atom-state": ["remote-thread-summaries-v3:ssh:build": rows]])
            .write(to: home.appendingPathComponent(".codex-global-state.json"))
        let tasks = try DesktopTaskCatalog(codexHome: home).remoteTasks
        let model = IslandModel(home: home)
        model.apply(BridgeUpdate(tasks: tasks, connected: true, liveCount: 0))
        XCTAssertTrue(tasks.allSatisfy { $0.phase == .unknown && !$0.hasUnreadContent })
        XCTAssertEqual(model.priorityTasks.count, 0)
        XCTAssertEqual(model.pendingTasks.count, 2, "Old and recent activity hints are both unconfirmed; age is not proof of liveness")
        XCTAssertEqual(model.recentTasks.count, 1, "Ordinary notLoaded history must stay quiet")
        XCTAssertEqual(model.compactStatus, "待同步", "A connected IPC socket does not confirm that remote tasks are idle")
    }
    @MainActor func testSourceFailuresAndExpiryWithdrawRunningStateWithoutMixingHosts() {
        let model = IslandModel(home: FileManager.default.temporaryDirectory)
        let now = Date()
        let id = UUID().uuidString
        let remote = IslandTask(id: id, title: "Remote", cwd: "D:\\build", updatedAt: 1, phase: .running,
                                source: .remote(hostID: "remote-control:env", name: nil))
        let local = IslandTask(id: id, title: "Local", cwd: "/build", updatedAt: 1, phase: .waiting)
        let cloud = IslandTask(id: "task_cloud", title: "Cloud", cwd: "", updatedAt: 1, phase: .running, source: .codexCloud)
        model.apply(BridgeUpdate(tasks: [remote, local], connected: true, liveCount: 2))
        model.applyOnlineCatalog(.success(OnlineCatalogUpdate(accountID: "a", hosts: [RemoteHost(id: "remote-control:env", name: "Windows", online: true)], cloudTasks: [cloud], fetchedAt: now)))
        XCTAssertEqual(model.tasks.count, 3)
        XCTAssertEqual(model.tasks.first { $0.id == remote.id }?.source.label, "Windows")
        XCTAssertEqual(model.tasks.first { $0.id == local.id }?.phase, .waiting)
        model.rebuildTasks(now: now.addingTimeInterval(91))
        XCTAssertEqual(model.tasks.first { $0.id == cloud.id }?.phase, .unknown)
        XCTAssertEqual(model.tasks.first { $0.id == remote.id }?.phase, .running, "IPC state remains independent of cloud polling")
        model.applyOnlineCatalog(.success(OnlineCatalogUpdate(accountID: "a", hosts: [RemoteHost(id: "remote-control:env", name: "Windows renamed", online: false)], cloudTasks: nil)))
        XCTAssertEqual(model.tasks.first { $0.id == remote.id }?.phase, .unknown)
        XCTAssertEqual(model.tasks.first { $0.id == remote.id }?.source.label, "Windows renamed")
        XCTAssertEqual(model.tasks.first { $0.id == cloud.id }?.phase, .unknown)
        XCTAssertEqual(model.tasks.first { $0.id == local.id }?.phase, .waiting)
    }

    @MainActor func testAccountChangeAndLogoutClearCloudMetadata() {
        let model = IslandModel(home: FileManager.default.temporaryDirectory)
        let cloud = IslandTask(id: "task_cloud", title: "Cloud", cwd: "", updatedAt: 1, phase: .running, source: .codexCloud)
        model.applyOnlineCatalog(.success(OnlineCatalogUpdate(accountID: "a", hosts: [], cloudTasks: [cloud])))
        XCTAssertEqual(model.tasks.count, 1)
        model.applyOnlineCatalog(.failure(.unavailable))
        XCTAssertEqual(model.tasks.first?.phase, .unknown)
        model.applyOnlineCatalog(.success(OnlineCatalogUpdate(accountID: "b", hosts: nil, cloudTasks: nil)))
        XCTAssertTrue(model.tasks.isEmpty)
        model.applyOnlineCatalog(.success(OnlineCatalogUpdate(accountID: "b", hosts: [], cloudTasks: [cloud])))
        model.applyOnlineCatalog(.failure(.authentication))
        XCTAssertTrue(model.tasks.isEmpty)
    }

    @MainActor func testOfflineHostAndAccountSwitchNeverPromoteCachedHints() {
        let model = IslandModel(home: FileManager.default.temporaryDirectory)
        var cached = IslandTask(id: UUID().uuidString, title: "Remote", cwd: "", updatedAt: 1,
                                source: .remote(hostID: "remote-control:env", name: nil))
        cached.activityHint = .active; cached.evidence = .cachedHint
        model.apply(BridgeUpdate(tasks: [cached], connected: true))
        model.applyOnlineCatalog(.success(OnlineCatalogUpdate(accountID: "a", hosts: [RemoteHost(id: "remote-control:env", name: "Windows", online: false)], cloudTasks: [])))
        XCTAssertEqual(model.compactStatus, "待同步")
        XCTAssertEqual(model.priorityTasks.count, 0)
        XCTAssertEqual(model.pendingTasks.first?.displayStatus, "主机离线 · 状态不可用")
        model.applyOnlineCatalog(.success(OnlineCatalogUpdate(accountID: "b", hosts: nil, cloudTasks: [])))
        XCTAssertTrue(model.tasks.isEmpty, "Do not expose a previous account's remote records while the new host scope is unverified")
        XCTAssertEqual(model.compactStatus, "待同步")
        model.applyOnlineCatalog(.success(OnlineCatalogUpdate(accountID: "b", hosts: [], cloudTasks: [])))
        XCTAssertEqual(model.compactStatus, "就绪")
        model.applyOnlineCatalog(.failure(.authentication))
        XCTAssertTrue(model.tasks.isEmpty)
    }

    @MainActor func testRenderMixedSourcesAndLongMachineName() throws {
        let model = IslandModel(home: FileManager.default.temporaryDirectory)
        model.showUsage = false
        model.connected = true
        model.tasks = [
            IslandTask(id: "local", title: "核对本机任务与状态", cwd: "/project", updatedAt: 6, phase: .waiting),
            IslandTask(id: "remote", title: "同步远程构建结果与需要进一步确认的详细任务标题", cwd: "D:\\code\\project", updatedAt: 5, phase: .running, source: .remote(hostID: "remote-control:env", name: "Windows")),
            IslandTask(id: "ssh", title: "校验构建输出", cwd: "/srv/build", updatedAt: 4, phase: .running, source: .remote(hostID: "ssh:build", name: "研发团队的 MacBook Pro 构建服务器")),
            IslandTask(id: "task_cloud", title: "云端代码审查", cwd: "team/project", updatedAt: 3, phase: .completed, hasUnreadContent: true, source: .codexCloud),
            IslandTask(id: "chat", title: "项目规划", cwd: "", updatedAt: 2, source: .chatGPT(isWork: true), statusNote: "缓存记录 · 无实时状态"),
            IslandTask(id: "offline", title: "检查离线机器上的结果", cwd: "/build", updatedAt: 1, source: .remote(hostID: "remote-control:offline", name: "Mac-mini"), statusNote: "主机离线 · 状态不可用")
        ]
        model.expand()
        model.showRecentTasks = true; model.presentedRecentTasks = true
        model.layout = IslandLayout.calculate(screen: ScreenGeometry(frame: NSRect(x: 0, y: 0, width: 1470, height: 956),
            visibleFrame: NSRect(x: 0, y: 78, width: 1470, height: 845), safeTop: 32, notchWidth: 179), expanded: true, floating: false)
        model.presentationBodyHeight = 540
        let host = NSHostingView(rootView: IslandView(model: model, hover: { _ in }))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 572)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        if let folder = ProcessInfo.processInfo.environment["CODEX_ISLAND_SCREENSHOT_DIR"] {
            let url = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("task-sources.png"))
            var pending = IslandTask(id: "pending", title: "远端任务有活动线索", cwd: "D:\\code\\project", updatedAt: 1,
                                     source: .remote(hostID: "remote-control:env", name: "Windows"), statusNote: "状态待同步 · 未确认当前活动")
            pending.activityHint = .active; pending.evidence = .cachedHint
            model.tasks = [pending]; model.showRecentTasks = false; model.presentedRecentTasks = false
            model.presentationBodyHeight = model.bodyHeight
            let pendingHost = NSHostingView(rootView: IslandView(model: model, hover: { _ in }))
            pendingHost.sizingOptions = []
            pendingHost.frame = NSRect(x: 0, y: 0, width: 460, height: model.layout.headerHeight + model.bodyHeight)
            pendingHost.layoutSubtreeIfNeeded()
            let pendingBitmap = try XCTUnwrap(pendingHost.bitmapImageRepForCachingDisplay(in: pendingHost.bounds))
            pendingHost.cacheDisplay(in: pendingHost.bounds, to: pendingBitmap)
            try XCTUnwrap(pendingBitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("pending-state.png"))
        }
    }
}
