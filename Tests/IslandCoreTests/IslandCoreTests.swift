import XCTest
import CoreGraphics
import SQLite3
@testable import IslandCore

final class IslandCoreTests: XCTestCase {
    func testFrameTransitionKeepsTopAndCenterFixedInBothDirectionsAndOnReversal() {
        let small = CGRect(x: 535.5, y: 918, width: 399, height: 38)
        let large = CGRect(x: 505, y: 528, width: 460, height: 428)
        for (from, to) in [(small, large), (large, small)] {
            let animation = PanelFrameTransition(from: from, to: to)
            for tick in 0...30 {
                let frame = animation.frame(at: Double(tick) / 30)
                XCTAssertEqual(frame.maxY, 956, accuracy: 0.001)
                XCTAssertEqual(frame.midX, 735, accuracy: 0.001)
                XCTAssertGreaterThanOrEqual(frame.height, small.height)
                XCTAssertLessThanOrEqual(frame.height, large.height)
            }
            let current = animation.frame(at: 0.37)
            let reversed = PanelFrameTransition(from: current, to: from)
            XCTAssertEqual(reversed.frame(at: 0), current)
            XCTAssertEqual(reversed.frame(at: 1), from)
        }
    }
    private let macBook = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                         visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 874),
                                         safeTop: 38, notchWidth: 210)

    func testMacBookControlsStayBelowNotchAndInsideVisibleScreen() {
        for expanded in [false, true] {
            let layout = IslandLayout.calculate(screen: macBook, expanded: expanded, floating: false)
            XCTAssertTrue(layout.attached)
            XCTAssertEqual(layout.frame.maxY, macBook.frame.maxY)
            XCTAssertEqual(layout.notchReservation, macBook.notchWidth + 16)
            XCTAssertGreaterThanOrEqual(layout.frame.width - layout.notchReservation, 112)
            XCTAssertEqual(layout.frame.midX, macBook.notchCenterX)
            if expanded {
                XCTAssertLessThanOrEqual(layout.bodyFrame.maxY, macBook.frame.maxY - macBook.safeTop)
                XCTAssertTrue(macBook.visibleFrame.contains(layout.bodyFrame))
            }
        }
    }
    func testExpandedBodyAvoidsTallerMenuBar() {
        var screen = macBook
        screen.visibleFrame.size.height -= 14
        let layout = IslandLayout.calculate(screen: screen, expanded: true, floating: false)
        XCTAssertLessThanOrEqual(layout.bodyFrame.maxY, screen.visibleFrame.maxY)
    }
    func testCompactNotchHeightFollowsScreenInsetsAcrossScalingAndHiddenMenuBar() {
        for (safeTop, menuHeight) in [(24.0, 24.0), (32, 33), (38, 38), (45, 45), (32, 50), (32, 0)] {
            let screen = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                        visibleFrame: CGRect(x: 0, y: 78, width: 1470, height: 878 - menuHeight),
                                        safeTop: safeTop, notchWidth: 179)
            let compact = IslandLayout.calculate(screen: screen, expanded: false, floating: false)
            let expanded = IslandLayout.calculate(screen: screen, expanded: true, floating: false)
            XCTAssertEqual(compact.frame.height, max(safeTop, menuHeight))
            XCTAssertEqual(compact.frame.maxY, screen.frame.maxY)
            XCTAssertEqual(compact.headerHeight, expanded.headerHeight)
            XCTAssertLessThanOrEqual(expanded.bodyFrame.maxY, screen.frame.maxY - safeTop)
            XCTAssertTrue(screen.visibleFrame.contains(expanded.bodyFrame))
        }
    }
    func testCompactUnnotchedAndFloatingScreensStayCompactAndVisible() {
        for menuHeight in [0.0, 24, 37, 50] {
            let screen = ScreenGeometry(frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
                                        visibleFrame: CGRect(x: -1920, y: -150, width: 1920, height: 1030 - menuHeight), safeTop: 0)
            let layout = IslandLayout.calculate(screen: screen, expanded: false, floating: false)
            XCTAssertFalse(layout.attached)
            XCTAssertTrue(screen.visibleFrame.contains(layout.frame))
            XCTAssertGreaterThanOrEqual(layout.frame.height, 32)
            XCTAssertLessThanOrEqual(layout.frame.height, 38)
            XCTAssertEqual(layout.frame.maxY, screen.visibleFrame.maxY - 8)
        }
        let floating = IslandLayout.calculate(screen: macBook, expanded: false, floating: true)
        XCTAssertFalse(floating.attached)
        XCTAssertTrue(macBook.visibleFrame.contains(floating.frame))
        XCTAssertEqual(floating.frame.height, 38)
    }
    func testNotchHeaderStaysCenteredAndBodyStaysBelowMenuThroughoutAnimation() {
        for (safeTop, menuHeight) in [(32.0, 33.0), (38, 38), (32, 50), (32, 0), (0, 24)] {
            let screen = ScreenGeometry(frame: CGRect(x: -400, y: 100, width: 1470, height: 956),
                                        visibleFrame: CGRect(x: -400, y: 178, width: 1470, height: 878 - menuHeight),
                                        safeTop: safeTop, notchWidth: safeTop > 0 ? 179 : 0)
            let compact = IslandLayout.calculate(screen: screen, expanded: false, floating: false)
            let expanded = IslandLayout.calculate(screen: screen, expanded: true, floating: false)
            for (from, to) in [(compact.frame, expanded.frame), (expanded.frame, compact.frame)] {
                let transition = PanelFrameTransition(from: from, to: to)
                for tick in 0...30 {
                    let frame = transition.frame(at: Double(tick) / 30)
                    let bodyTop = frame.maxY - compact.headerHeight
                    XCTAssertLessThanOrEqual(bodyTop, screen.visibleFrame.maxY + 0.001)
                    XCTAssertLessThanOrEqual(bodyTop, screen.frame.maxY - safeTop + 0.001)
                    if compact.attached {
                        XCTAssertEqual(frame.midX, screen.notchCenterX, accuracy: 0.001)
                        XCTAssertEqual(frame.maxY, screen.frame.maxY, accuracy: 0.001)
                    } else {
                        XCTAssertTrue(screen.visibleFrame.contains(frame))
                    }
                }
            }
            if compact.attached {
                XCTAssertEqual(compact.frame.width, screen.notchWidth + 128)
                XCTAssertEqual(compact.frame.height, max(safeTop, menuHeight))
            }
        }
    }
    func testExternalScreenWithNegativeCoordinatesAndDock() {
        let screen = ScreenGeometry(frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
                                    visibleFrame: CGRect(x: -1880, y: -200, width: 1880, height: 1055), safeTop: 0)
        let layout = IslandLayout.calculate(screen: screen, expanded: true, floating: false)
        XCTAssertFalse(layout.attached)
        XCTAssertTrue(screen.visibleFrame.contains(layout.frame))
        XCTAssertEqual(layout.notchReservation, 0)
    }
    func testFloatingModeOnMacBookDoesNotEnterMenuBar() {
        let layout = IslandLayout.calculate(screen: macBook, expanded: true, floating: true)
        XCTAssertFalse(layout.attached)
        XCTAssertTrue(macBook.visibleFrame.contains(layout.frame))
        XCTAssertEqual(layout.frame.maxY, macBook.visibleFrame.maxY - 8)
    }
    func testShortScaledDisplayClampsBodyHeight() {
        let screen = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 800, height: 450),
                                    visibleFrame: CGRect(x: 0, y: 100, width: 800, height: 325), safeTop: 0)
        let layout = IslandLayout.calculate(screen: screen, expanded: true, floating: true, bodyHeight: 500)
        XCTAssertTrue(screen.visibleFrame.contains(layout.frame))
        XCTAssertGreaterThan(layout.bodyFrame.height, 200)
    }
    func testFragmentedAndMultipleIPCFrames() throws {
        let a = Data("hello".utf8), b = Data("world".utf8)
        let frames = IPCFrameDecoder.encode(a) + IPCFrameDecoder.encode(b)
        var decoder = IPCFrameDecoder()
        XCTAssertEqual(try decoder.append(frames.prefix(2)), [])
        XCTAssertEqual(try decoder.append(frames.subdata(in: 2..<7)), [])
        XCTAssertEqual(try decoder.append(frames.suffix(from: 7)), [a, b])
    }
    func testOversizedIPCFrameIsRejectedBeforeBufferingPayload() {
        var decoder = IPCFrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([255, 255, 255, 127])))
    }
    func testDecoderHandlesNonZeroDataIndicesAcrossReads() throws {
        let first = IPCFrameDecoder.encode(Data(repeating: 65, count: 240))
        let second = IPCFrameDecoder.encode(Data(repeating: 66, count: 300))
        var decoder = IPCFrameDecoder()
        XCTAssertEqual(try decoder.append(first + second.prefix(120)), [Data(repeating: 65, count: 240)])
        XCTAssertEqual(try decoder.append(second.suffix(from: 120)), [Data(repeating: 66, count: 300)])
        XCTAssertEqual(try decoder.append(first), [Data(repeating: 65, count: 240)])
    }
    private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    func testSnapshotRetainsOnlyMetadataAndMapsRealRuntimeState() throws {
        let snapshot = try json(#"{"type":"snapshot","revision":5,"conversationState":{"title":"A","turns":[{"text":"private"}],"threadRuntimeStatus":{"type":"active","activeFlags":["waitingOnApproval"]}}}"#)
        let state = try XCTUnwrap(LiveTaskState(change: snapshot))
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertNil(state.document["turns"])
        XCTAssertEqual(state.title, "A")
    }
    func testMetadataPatchesFollowRevisionsAndIgnoreChatContent() throws {
        var state = try XCTUnwrap(LiveTaskState(change: json(#"{"type":"snapshot","revision":1,"conversationState":{"threadRuntimeStatus":{"type":"active","activeFlags":[]},"hasUnreadTurn":false}}"#)))
        XCTAssertEqual(state.phase, .running)
        XCTAssertTrue(state.apply(change: try json(#"{"type":"patches","baseRevision":1,"revision":2,"patches":[{"op":"replace","path":["threadRuntimeStatus","type"],"value":"idle"},{"op":"replace","path":["hasUnreadTurn"],"value":true},{"op":"add","path":["turns",0],"value":{"text":"private"}}]}"#)))
        XCTAssertEqual(state.phase, .completed)
        XCTAssertNil(state.document["turns"])
        XCTAssertFalse(state.apply(change: try json(#"{"type":"patches","baseRevision":0,"revision":3,"patches":[]}"#)))
        XCTAssertEqual(state.revision, 2)
    }
    func testWaitingFlagPatchAndUnknownStatuses() throws {
        var state = try XCTUnwrap(LiveTaskState(change: json(#"{"type":"snapshot","revision":1,"conversationState":{"threadRuntimeStatus":{"type":"active","activeFlags":[]}}}"#)))
        XCTAssertTrue(state.apply(change: try json(#"{"type":"patches","baseRevision":1,"revision":2,"patches":[{"op":"add","path":["threadRuntimeStatus","activeFlags",0],"value":"waitingOnUserInput"}]}"#)))
        XCTAssertEqual(state.phase, .waiting)
        let unknown = try XCTUnwrap(LiveTaskState(change: json(#"{"type":"snapshot","revision":1,"conversationState":{"threadRuntimeStatus":{"type":"notLoaded"}}}"#)))
        XCTAssertEqual(unknown.phase, .unknown)
    }
    func testLinksEscapePromptAndRejectInvalidTaskIdentifiers() {
        let prompt = "测试 & a=1 # + 你好\n第二行"
        let url = CodexLink.newThread(prompt: prompt)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, prompt)
        XCTAssertNil(CodexLink.thread("../../settings?prompt=bad"))
        XCTAssertNotNil(CodexLink.thread(UUID().uuidString))
    }
    func testCatalogUsesSavedNamesAndExcludesBackgroundExecTasks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("island-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(folder.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        let id = UUID().uuidString
        let sql = """
        CREATE TABLE threads (id TEXT, name TEXT, title TEXT, cwd TEXT, updated_at INTEGER, archived INTEGER, source TEXT, has_user_event INTEGER);
        INSERT INTO threads VALUES ('\(id)', '简短任务名', 'A very long raw user prompt', '/tmp/project', 100, 0, 'vscode', 0);
        INSERT INTO threads VALUES ('\(UUID().uuidString)', NULL, 'Background worker', '/tmp/project', 200, 0, 'exec', 1);
        INSERT INTO threads VALUES ('\(UUID().uuidString)', 'Archived', '', '/tmp/project', 300, 1, 'vscode', 1);
        INSERT INTO threads VALUES ('\(UUID().uuidString)', 'Internal title generator', '', '/tmp/project', 400, 0, 'vscode', 0);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let tasks = try TaskCatalog(codexHome: folder).read()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.title, "简短任务名")
        XCTAssertEqual(tasks.first?.phase, .unknown)
    }
    func testPriorityOrderPlacesWaitingRunningAndUnreadAboveRecentTasks() {
        func task(_ id: String, _ phase: TaskPhase, _ time: Double, unread: Bool = false) -> IslandTask {
            IslandTask(id: id, title: id, cwd: "/project", updatedAt: time, phase: phase, hasUnreadContent: unread)
        }
        let tasks = [task("old-idle", .idle, 100), task("new-recent", .unknown, 500),
                     task("unread", .unknown, 300, unread: true), task("done", .completed, 250),
                     task("running", .running, 200), task("waiting", .waiting, 10), task("failed", .failed, 20)]
        XCTAssertEqual(tasks.sorted(by: IslandTask.precedes).map(\.id),
                       ["waiting", "failed", "running", "unread", "done", "new-recent", "old-idle"])
    }
    func testUnreadRunningTaskStaysInRunningSectionAndClearsAfterReading() throws {
        var state = try XCTUnwrap(LiveTaskState(change: json(#"{"type":"snapshot","revision":1,"conversationState":{"threadRuntimeStatus":{"type":"active","activeFlags":[]},"hasUnreadTurn":true,"unreadMessageCount":2}}"#)))
        let task = IslandTask(id: "one", title: "Task", cwd: "/", updatedAt: 1,
                              phase: state.phase, hasUnreadContent: state.hasUnreadContent)
        XCTAssertEqual(task.section, .running)
        XCTAssertTrue(task.hasUnreadContent)
        XCTAssertTrue(state.apply(change: try json(#"{"type":"patches","baseRevision":1,"revision":2,"patches":[{"op":"replace","path":["hasUnreadTurn"],"value":false},{"op":"replace","path":["unreadMessageCount"],"value":0}]}"#)))
        XCTAssertFalse(state.hasUnreadContent)
    }
    func testUnloadedUnreadContentIsHighlightedWithoutInventingCompletion() throws {
        let state = try XCTUnwrap(LiveTaskState(change: json(#"{"type":"snapshot","revision":1,"conversationState":{"threadRuntimeStatus":{"type":"notLoaded"},"unreadMessageCount":1}}"#)))
        let task = IslandTask(id: "one", title: "Task", cwd: "/", updatedAt: 1,
                              phase: state.phase, hasUnreadContent: state.hasUnreadContent)
        XCTAssertEqual(task.phase, .unknown)
        XCTAssertEqual(task.section, .updates)
        XCTAssertEqual(task.displayStatus, "有新内容 · 待查看")
    }
    func testLiveActivityTimeSupportsSecondsAndMilliseconds() throws {
        let state = try XCTUnwrap(LiveTaskState(change: json(#"{"type":"snapshot","revision":1,"conversationState":{"updatedAt":1788840000,"recencyAt":1788840012000}}"#)))
        XCTAssertEqual(state.activityAt, 1788840012)
    }
}
