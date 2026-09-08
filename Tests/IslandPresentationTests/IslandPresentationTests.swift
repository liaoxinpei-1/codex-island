import AppKit
import SwiftUI
import XCTest
import IslandCore
@testable import CodexIsland

final class IslandPresentationTests: XCTestCase {
    @MainActor func testLoadingQuotaKeepsVisibleIconOnBlackPanel() throws {
        let model = IslandModel(home: FileManager.default.homeDirectoryForCurrentUser)
        model.showUsage = true
        model.tasks = [IslandTask(id: "active", title: "Active", cwd: "/test", updatedAt: 1, phase: .running)]
        model.expand()
        model.layout = IslandLayout.calculate(screen: ScreenGeometry(
            frame: NSRect(x: 0, y: 0, width: 1470, height: 956),
            visibleFrame: NSRect(x: 0, y: 78, width: 1470, height: 845),
            safeTop: 32, notchWidth: 179), expanded: true, floating: false)
        model.presentationBodyHeight = 210
        model.usageRefreshState = .loading
        let host = NSHostingView(rootView: IslandView(model: model, hover: { _ in }))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 243)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / 460
        var visiblePixels = 0
        // The refresh control is the rightmost 16-point icon in the first body row.
        for y in Int(43 * scale)..<Int(59 * scale) {
            for x in Int(428 * scale)..<Int(444 * scale) {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.25 { visiblePixels += 1 }
            }
        }
        XCTAssertGreaterThan(visiblePixels, 12, "Loading must not leave the refresh control blank")
    }
    @MainActor func testUsageRefreshFeedbackReturnsToIdleAndDoesNotReportFailureAsSuccess() async throws {
        let model = IslandModel(home: FileManager.default.homeDirectoryForCurrentUser)
        defer { model.stop() }
        let response = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"rateLimits":{"primary":{"usedPercent":25}}}"#.utf8))
        let snapshot = try XCTUnwrap(UsageSnapshot(response: response))
        model.usageRefreshState = .loading
        model.completeUsageRefresh(.success(snapshot))
        XCTAssertEqual(model.usageRefreshState, .success)
        XCTAssertFalse(model.usageLoading)
        XCTAssertEqual(model.usageText, "75%")
        try await Task.sleep(for: .milliseconds(1550))
        XCTAssertEqual(model.usageRefreshState, .idle)
        model.completeUsageRefresh(.failure(.timeout))
        XCTAssertEqual(model.usageRefreshState, .failure)
        XCTAssertEqual(model.usageText, "—")
        XCTAssertEqual(model.usageRefreshHelp, "刷新失败，点击重试")
    }
    @MainActor func testUsageDisplayShowsPlaceholderForUnavailableAndStaleQuotaWithoutUpdateTime() throws {
        let model = IslandModel(home: FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertEqual(model.usageText, "—")
        let response = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"rateLimits":{"primary":{"usedPercent":23,"windowDurationMins":10080}}}"#.utf8))
        model.usageSnapshot = UsageSnapshot(response: response)
        XCTAssertEqual(model.usageText, "77%")
        XCTAssertEqual(model.usageHelp, "每周额度剩余 77%")
        model.usageSnapshot = UsageSnapshot(response: response, fetchedAt: Date().addingTimeInterval(-121))
        XCTAssertEqual(model.usageText, "—")
    }
    @MainActor func testCompactCountCombinesPriorityTasksWithoutDoubleCountingUnreadRunningTask() {
        let model = IslandModel(home: FileManager.default.homeDirectoryForCurrentUser)
        model.connected = true
        model.tasks = [
            IslandTask(id: "running", title: "Running", cwd: "/test", updatedAt: 1, phase: .running, hasUnreadContent: true),
            IslandTask(id: "waiting", title: "Waiting", cwd: "/test", updatedAt: 1, phase: .waiting),
            IslandTask(id: "failed", title: "Failed", cwd: "/test", updatedAt: 1, phase: .failed),
            IslandTask(id: "completed", title: "Completed", cwd: "/test", updatedAt: 1, phase: .completed),
            IslandTask(id: "unread", title: "Unread", cwd: "/test", updatedAt: 1, hasUnreadContent: true),
            IslandTask(id: "history", title: "History", cwd: "/test", updatedAt: 1, phase: .idle)
        ]
        XCTAssertEqual(model.compactStatus, "×5")
        model.tasks[0].phase = .idle
        XCTAssertEqual(model.compactStatus, "×5", "Unread work remains counted after running ends")
        model.tasks[0].hasUnreadContent = false
        XCTAssertEqual(model.compactStatus, "×4")
        model.tasks = Array(model.tasks.suffix(1))
        XCTAssertEqual(model.compactStatus, "就绪")
        model.connected = false
        XCTAssertEqual(model.compactStatus, "离线")
    }
    @MainActor func testHeaderClickPinsHoverPreviewAndNextClickCollapses() {
        let model = IslandModel(home: FileManager.default.homeDirectoryForCurrentUser)
        model.expand(.tasks, pin: false)
        model.toggleFromHeader()
        XCTAssertTrue(model.expanded)
        XCTAssertTrue(model.pinned)
        model.toggleFromHeader()
        XCTAssertFalse(model.expanded)
        model.toggleFromHeader()
        XCTAssertTrue(model.expanded)
        XCTAssertTrue(model.pinned)
    }
    @MainActor func testCollapsingSurfaceFillsCurrentHostBoundsInsteadOfJumpingToTargetWidth() throws {
        let model = IslandModel(home: FileManager.default.homeDirectoryForCurrentUser)
        model.layout = IslandLayout.calculate(screen: ScreenGeometry(
            frame: NSRect(x: 0, y: 0, width: 1470, height: 956),
            visibleFrame: NSRect(x: 0, y: 78, width: 1470, height: 845),
            safeTop: 32, notchWidth: 179), expanded: false, floating: false)
        model.presentationBodyHeight = 210
        model.expanded = false
        let host = NSHostingView(rootView: IslandView(model: model, hover: { _ in }))
        host.sizingOptions = []

        // Sample two intermediate native-window sizes, both wider than the collapsed target.
        for size in [NSSize(width: 460, height: 220), NSSize(width: 425, height: 120)] {
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scaleX = CGFloat(bitmap.pixelsWide) / size.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / size.height
            for x in [CGFloat(3), size.width - 4] {
                let color = try XCTUnwrap(bitmap.colorAt(x: Int(x * scaleX), y: Int(size.height / 2 * scaleY))?.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(color.alphaComponent, 0.99, "Transparent side gap during collapse at width \(size.width)")
                XCTAssertLessThan(max(color.redComponent, color.greenComponent, color.blueComponent), 0.01)
            }
        }
    }

    @MainActor func testCollapseRetainsOutgoingPageUntilNextExpansion() {
        let model = IslandModel(home: FileManager.default.homeDirectoryForCurrentUser)
        model.expand(.settings)
        model.collapse()
        XCTAssertEqual(model.page, .settings)
        XCTAssertFalse(model.expanded)
        model.expand()
        XCTAssertEqual(model.page, .tasks)
    }

    @MainActor func testRecentTaskRowsRemainUntilShrinkCompletesAndSurviveReversal() {
        let model = IslandModel(home: FileManager.default.homeDirectoryForCurrentUser)
        model.expand()
        model.toggleRecentTasks()
        model.finishLayoutTransition()
        model.toggleRecentTasks()
        XCTAssertFalse(model.showRecentTasks)
        XCTAssertTrue(model.presentedRecentTasks, "Rows must remain while their viewport shrinks")
        model.toggleRecentTasks()
        model.finishLayoutTransition()
        XCTAssertTrue(model.presentedRecentTasks, "Reversing the shrink must retain the rows")
        model.toggleRecentTasks()
        model.finishLayoutTransition()
        XCTAssertFalse(model.presentedRecentTasks)
    }

    @MainActor func testTaskFooterTracksIntermediateWindowHeight() throws {
        let model = IslandModel(home: FileManager.default.homeDirectoryForCurrentUser)
        model.tasks = [IslandTask(id: "active", title: "Active", cwd: "/test", updatedAt: 1, phase: .running)]
        model.expand()
        model.presentationBodyHeight = 210 // Final compact list height must not position the footer early.
        model.resizingExpandedBody = true
        let host = NSHostingView(rootView: IslandView(model: model, hover: { _ in }))
        host.sizingOptions = []
        for height in [CGFloat(400), CGFloat(330), CGFloat(270)] {
            host.frame = NSRect(x: 0, y: 0, width: 460, height: height)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsHigh) / height
            let color = try XCTUnwrap(bitmap.colorAt(x: Int(80 * scale), y: Int((height - 34) * scale))?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(color.redComponent, 0.7, "New-chat button must stay near the moving bottom at height \(height)")
        }
    }
}
