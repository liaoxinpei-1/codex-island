import AppKit
import IslandCore

private final class OnlineDiagnosticResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<OnlineCatalogUpdate, OnlineCatalogError>?
    func set(_ value: Result<OnlineCatalogUpdate, OnlineCatalogError>) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Result<OnlineCatalogUpdate, OnlineCatalogError>? { lock.lock(); defer { lock.unlock() }; return value }
}

if CommandLine.arguments.contains("--version") {
    print("Codex Island 0.1.24")
} else if CommandLine.arguments.contains("--diagnose") || CommandLine.arguments.contains("--diagnose-sources") {
    // Read-only check; does not show windows, create tasks, or modify the Codex client.
    let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    let lock = NSLock()
    var latest = BridgeUpdate()
    let online = OnlineDiagnosticResult()
    let includeOnline = CommandLine.arguments.contains("--diagnose-sources")
    let onlineReader = OnlineCatalogReader(executable: PetLibrary.codexApplication()?.appendingPathComponent("Contents/Resources/codex"), home: home)
    if includeOnline { onlineReader.refresh { result in online.set(result) } }
    let observer = IPCObserver(home: home) { update in lock.lock(); latest = update; lock.unlock() }
    observer.start()
    RunLoop.main.run(until: Date().addingTimeInterval(4))
    let deadline = Date().addingTimeInterval(22)
    while includeOnline && Date() < deadline {
        let finished = online.get() != nil
        if finished { break }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    observer.stop()
    onlineReader.stop()
    lock.lock(); let update = latest; lock.unlock()
    let library = PetLibrary(home: home)
    var info: [String: Any] = [
        "version": "0.1.24", "connected": update.connected, "liveTaskCount": update.liveCount,
        "catalogCount": update.tasks.count, "catalogAvailable": update.catalogAvailable,
        "pendingTaskCount": update.tasks.filter(\.hasPendingActivity).count,
        "sourceCoverage": update.coverage.mapValues(\.diagnostic),
        "message": update.message, "petCount": library.pets.count,
        "defaultPetLoads": library.pets.first.map { library.image(for: $0.id) != nil } ?? false,
        "screenCount": NSScreen.screens.count,
        "snapshotProtocolVersion": IPCObserver.supportedSnapshotVersion
    ]
    if includeOnline {
        let remote = update.tasks.filter { if case .remote = $0.source { return true }; return false }
        info["remoteCatalogCount"] = remote.count
        info["remoteRuntimeStatusCount"] = remote.filter { $0.phase != .unknown }.count
        let result = online.get()
        if case .success(let catalog) = result {
            info["hostNamesAvailable"] = catalog.hosts != nil
            info["remoteMachineNames"] = catalog.hosts?.map(\.name).sorted() ?? []
            info["cloudAvailable"] = catalog.cloudTasks != nil
            info["cloudTaskCount"] = catalog.cloudTasks?.count ?? 0
            info["cachedChatCount"] = (try? DesktopTaskCatalog(codexHome: home, accountID: catalog.accountID).chatTasks(accountID: catalog.accountID).count) ?? 0
        } else { info["onlineCatalogAvailable"] = false }
    }
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
