import Foundation
import Darwin
import XCTest
import IslandCore
@testable import CodexIsland

final class IPCObserverTests: XCTestCase {
    func testValidHeartbeatPatchKeepsStateUntilANonresponsiveRefresh() throws {
        try exerciseObserver(heartbeatInterval: 2, snapshotTimeout: 0.2, checkHeartbeat: true)
    }

    func testSubscriptionsAndRevisionsAreIsolatedByHostAndUnsupportedVersionClearsState() throws {
        try exerciseObserver()
    }

    private func exerciseObserver(heartbeatInterval: TimeInterval = 30, snapshotTimeout: TimeInterval = 10,
                                  checkHeartbeat: Bool = false) throws {
        // Two machines deliberately have the same thread UUID.
        let home = URL(fileURLWithPath: "/tmp/island-ipc-" + String(UUID().uuidString.prefix(8)))
        let ipc = home.appendingPathComponent("ipc")
        try FileManager.default.createDirectory(at: ipc, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        let id = UUID().uuidString
        let rows: (String) -> [[String: Any]] = { [["conversationId": id, "hostId": $0, "title": "Test", "updatedAt": 1]] }
        try JSONSerialization.data(withJSONObject: ["electron-persisted-atom-state": [
            "remote-thread-summaries-v3:ssh:one": rows("ssh:one"), "remote-thread-summaries-v3:ssh:two": rows("ssh:two")
        ]]).write(to: home.appendingPathComponent(".codex-global-state.json"))
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer { Darwin.close(server) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = ipc.appendingPathComponent("ipc.sock").path
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for i in bytes.indices { raw[i] = UInt8(bitPattern: bytes[i]) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0); XCTAssertEqual(chmod(path, 0o600), 0); XCTAssertEqual(listen(server, 1), 0)
        let lock = NSLock()
        var latest = BridgeUpdate()
        let observer = IPCObserver(home: home, heartbeatInterval: heartbeatInterval, snapshotTimeout: snapshotTimeout) { update in lock.lock(); latest = update; lock.unlock() }
        observer.start()
        defer { observer.stop() }
        var descriptor = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
        XCTAssertGreaterThan(poll(&descriptor, 1, 3000), 0)
        let client = accept(server, nil, nil)
        guard client >= 0 else { return XCTFail("Observer did not connect") }
        defer { Darwin.close(client) }
        var decoder = IPCFrameDecoder(), pending: [JSONValue] = []
        func receive() throws -> JSONValue {
            let deadline = Date().addingTimeInterval(3)
            while pending.isEmpty && Date() < deadline {
                var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
                if poll(&descriptor, 1, 100) > 0 {
                    var bytes = [UInt8](repeating: 0, count: 65536)
                    let count = Darwin.read(client, &bytes, bytes.count)
                    if count <= 0 { break }
                    pending += try decoder.append(Data(bytes.prefix(count))).map { try JSONDecoder().decode(JSONValue.self, from: $0) }
                }
            }
            return try XCTUnwrap(pending.isEmpty ? nil : pending.removeFirst())
        }
        func send(_ object: [String: Any]) throws {
            let data = IPCFrameDecoder.encode(try JSONSerialization.data(withJSONObject: object))
            try data.withUnsafeBytes { bytes in
                guard Darwin.write(client, bytes.baseAddress, bytes.count) == bytes.count else { throw NSError(domain: "TestIPC", code: 1) }
            }
        }
        let handshake = try receive()
        try send(["type": "response", "method": "initialize", "requestId": handshake["requestId"]!.string!, "resultType": "success", "result": ["clientId": "observer"]])
        let follows = try [receive(), receive()]
        XCTAssertEqual(Set(follows.compactMap { $0["params"]?["hostId"]?.string }), ["ssh:one", "ssh:two"])
        XCTAssertTrue(follows.allSatisfy { $0["params"]?["conversationId"]?.string == id && $0["params"]?["following"]?.bool == true })
        func snapshot(host: String, status: String, version: Int = 11) throws {
            try send(["type": "broadcast", "method": "thread-stream-state-changed", "version": version, "sourceClientId": host,
                      "params": ["hostId": host, "conversationId": id, "change": ["type": "snapshot", "revision": 1,
                      "conversationState": ["title": host, "threadRuntimeStatus": ["type": status], "hasUnreadTurn": false]]]])
        }
        func eventually(_ predicate: (BridgeUpdate) -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                lock.lock(); let value = latest; lock.unlock()
                if predicate(value) { return true }
                Thread.sleep(forTimeInterval: 0.03)
            }
            return false
        }
        try snapshot(host: "ssh:one", status: "active")
        try snapshot(host: "ssh:two", status: "idle")
        XCTAssertTrue(eventually { value in
            value.tasks.first { $0.source.hostID == "ssh:one" }?.phase == .running &&
            value.tasks.first { $0.source.hostID == "ssh:two" }?.phase == .idle
        })
        if checkHeartbeat {
            let refresh = try [receive(), receive()]
            XCTAssertEqual(Set(refresh.compactMap { $0["params"]?["hostId"]?.string }), ["ssh:one", "ssh:two"])
            // Only one host responds, with a continuous patch instead of a full snapshot.
            try send(["type": "broadcast", "method": "thread-stream-state-changed", "version": 11, "sourceClientId": "ssh:one",
                      "params": ["hostId": "ssh:one", "conversationId": id, "change": ["type": "patches", "baseRevision": 1,
                      "revision": 2, "patches": [["op": "add", "path": ["updatedAt"], "value": 1234]]]]])
            // Wait for the other host to expire, proving the old deadline and a publish cycle have elapsed.
            XCTAssertTrue(eventually { $0.tasks.first { $0.source.hostID == "ssh:two" }?.phase == .unknown })
            lock.lock(); let refreshed = latest; lock.unlock()
            XCTAssertEqual(refreshed.liveCount, 1)
            let active = try XCTUnwrap(refreshed.tasks.first { $0.source.hostID == "ssh:one" })
            XCTAssertEqual(active.phase, .running)
            XCTAssertEqual(active.updatedAt, 1234)
            XCTAssertEqual(refreshed.tasks.filter { $0.section != .recent }.count, 1)

            // A later completely silent heartbeat must still expire the previously healthy task.
            _ = try [receive(), receive()]
            XCTAssertTrue(eventually { $0.liveCount == 0 && $0.tasks.allSatisfy { $0.phase == .unknown } })
            return
        }
        try send(["type": "broadcast", "method": "client-status-changed",
                  "params": ["clientId": "ssh:two", "status": "disconnected"]])
        XCTAssertTrue(eventually { $0.liveCount == 1 &&
            $0.tasks.first { $0.source.hostID == "ssh:one" }?.phase == .running &&
            $0.tasks.first { $0.source.hostID == "ssh:two" }?.phase == .unknown
        })
        try snapshot(host: "ssh:two", status: "idle")
        XCTAssertTrue(eventually { $0.liveCount == 2 })
        try send(["type": "broadcast", "method": "thread-archived", "version": 2,
                  "params": ["hostId": "ssh:two", "conversationId": id]])
        let unsubscribe = try receive()
        XCTAssertEqual(unsubscribe["params"]?["hostId"]?.string, "ssh:two")
        XCTAssertEqual(unsubscribe["params"]?["following"]?.bool, false)
        XCTAssertTrue(eventually { $0.tasks.count == 1 })
        try send(["type": "broadcast", "method": "thread-unarchived", "version": 1,
                  "params": ["hostId": "ssh:two", "conversationId": id]])
        let restored = try receive()
        XCTAssertEqual(restored["params"]?["hostId"]?.string, "ssh:two")
        XCTAssertEqual(restored["params"]?["following"]?.bool, true)
        try snapshot(host: "ssh:two", status: "idle")
        try send(["type": "broadcast", "method": "thread-stream-state-changed", "version": 11, "sourceClientId": "ssh:two",
                  "params": ["hostId": "ssh:two", "conversationId": id, "change": ["type": "patches", "baseRevision": 0, "revision": 2, "patches": []]]])
        let resubscribe = try receive()
        XCTAssertEqual(resubscribe["params"]?["hostId"]?.string, "ssh:two")
        XCTAssertTrue(eventually { $0.tasks.first { $0.source.hostID == "ssh:one" }?.phase == .running && $0.liveCount == 1 })
        try snapshot(host: "ssh:one", status: "active", version: 99)
        XCTAssertTrue(eventually { !$0.connected && $0.liveCount == 0 && $0.tasks.allSatisfy { $0.phase == .unknown } })
    }
}
