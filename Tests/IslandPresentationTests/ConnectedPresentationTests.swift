import AppKit
import SwiftUI
import XCTest
import IslandCore
@testable import CodexIsland

final class ConnectedPresentationTests: XCTestCase {
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
        }
    }
}
