import AppKit
import IslandCore

if CommandLine.arguments.contains("--version") {
    print("Codex Island 0.1.22")
} else if CommandLine.arguments.contains("--diagnose") {
    // Read-only check; does not show windows, create tasks, or modify the Codex client.
    let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    let lock = NSLock()
    var latest = BridgeUpdate()
    let observer = IPCObserver(home: home) { update in lock.lock(); latest = update; lock.unlock() }
    observer.start()
    RunLoop.main.run(until: Date().addingTimeInterval(4))
    observer.stop()
    lock.lock(); let update = latest; lock.unlock()
    let library = PetLibrary(home: home)
    let info: [String: Any] = [
        "version": "0.1.22", "connected": update.connected, "liveTaskCount": update.liveCount,
        "catalogCount": update.tasks.count, "catalogAvailable": update.catalogAvailable,
        "message": update.message, "petCount": library.pets.count,
        "defaultPetLoads": library.pets.first.map { library.image(for: $0.id) != nil } ?? false,
        "screenCount": NSScreen.screens.count,
        "snapshotProtocolVersion": IPCObserver.supportedSnapshotVersion
    ]
    if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
