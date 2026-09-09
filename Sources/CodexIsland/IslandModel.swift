import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import IslandCore

@MainActor final class IslandModel: ObservableObject {
    enum Page { case tasks, chat, settings }
    enum UsageRefreshState { case idle, loading, success, failure }
    let home: URL
    let library: PetLibrary
    @Published var tasks: [IslandTask] = []
    @Published var connection = "正在连接 Codex…"
    @Published var connected = false
    @Published var liveCount = 0
    @Published var catalogAvailable = true
    @Published var sourceMessages: [String] = ["正在读取云端任务和机器名称…"]
    @Published var expanded = false
    @Published var pinned = false
    @Published var page = Page.tasks
    @Published var showRecentTasks = false
    @Published var presentedRecentTasks = false
    @Published var presentationBodyHeight: CGFloat = 0
    @Published var resizingExpandedBody = false
    @Published var prompt = ""
    @Published var feedback: String?
    @Published var petImage: CGImage?
    @Published var pets: [PetDescriptor] = []
    @Published var layout = IslandLayout.calculate(screen: ScreenGeometry(frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 0, width: 1440, height: 875), safeTop: 0), expanded: false, floating: false)
    @Published var screens: [(id: String, name: String)] = []
    @Published var selectedScreen = UserDefaults.standard.string(forKey: "displayID") ?? "auto"
    @Published var floating = UserDefaults.standard.bool(forKey: "floating")
    @Published var selectedPet = UserDefaults.standard.string(forKey: "petID") ?? "builtin:codex"
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var shortcutAvailable = false
    @Published var usageSnapshot: UsageSnapshot?
    @Published var usageRefreshState = UsageRefreshState.idle
    var usageLoading: Bool { usageRefreshState == .loading }
    var usageRefreshHelp: String {
        switch usageRefreshState {
        case .idle: return "刷新额度"
        case .loading: return "正在刷新额度"
        case .success: return "额度刷新成功"
        case .failure: return "刷新失败，点击重试"
        }
    }
    @Published var usageMessage = "正在读取额度…"
    @Published var showUsage = UserDefaults.standard.object(forKey: "showUsage") as? Bool ?? true
    var modalOpen = false
    var onLayoutChange: (() -> Void)?
    var onFocusInput: (() -> Void)?
    var onStatusChange: (() -> Void)?
    private var observer: IPCObserver?
    private var lastBridge = BridgeUpdate()
    private var onlineReader: OnlineCatalogReader?
    private var onlineTimer: Timer?
    private var accountID: String?
    private var hosts: [String: RemoteHost] = [:]
    private var hasHostCatalog = false
    private var hostFetchAt = Date.distantPast
    private var cloudFetchAt = Date.distantPast
    private var cloudTasks: [IslandTask] = []
    private var cachedChats: [IslandTask] = []
    private var cloudAvailable = false
    private var hostsAvailable = false
    private var onlineMessage: String? = "正在读取云端任务和机器名称…"
    private var usageReader: UsageReader?
    private var usageTimer: Timer?
    private var usageFeedbackReset: DispatchWorkItem?
    private var lastUsageAttempt = Date.distantPast

    init(home: URL) {
        self.home = home; self.library = PetLibrary(home: home)
        reloadPets()
    }
    func start() {
        observer = IPCObserver(home: home) { [weak self] update in
            DispatchQueue.main.async { self?.apply(update) }
        }
        observer?.start()
        let bundled = PetLibrary.codexApplication()?.appendingPathComponent("Contents/Resources/codex")
        let candidates = [bundled, URL(fileURLWithPath: "/opt/homebrew/bin/codex"), URL(fileURLWithPath: "/usr/local/bin/codex")].compactMap { $0 }
        let executable = candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        usageReader = UsageReader(executable: executable)
        onlineReader = OnlineCatalogReader(executable: executable, home: home)
        refreshOnlineCatalog()
        let onlineTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOnlineCatalog() }
        }
        self.onlineTimer = onlineTimer
        RunLoop.main.add(onlineTimer, forMode: .common)
        refreshUsage()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.expanded, self.page == .tasks else { return }
                self.refreshUsage()
            }
        }
        usageTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stop() {
        observer?.stop(); usageTimer?.invalidate(); usageFeedbackReset?.cancel(); usageReader?.stop()
        onlineTimer?.invalidate(); onlineReader?.stop()
    }
    private func refreshOnlineCatalog() {
        onlineReader?.refresh { [weak self] result in
            DispatchQueue.main.async { self?.applyOnlineCatalog(result) }
        }
    }
    func applyOnlineCatalog(_ result: Result<OnlineCatalogUpdate, OnlineCatalogError>) {
        switch result {
        case .success(let update):
            if accountID != update.accountID {
                hosts = [:]; cloudTasks = []; cachedChats = []; hasHostCatalog = false
                hostFetchAt = .distantPast; cloudFetchAt = .distantPast
            }
            accountID = update.accountID; onlineMessage = nil
            hostsAvailable = update.hosts != nil; cloudAvailable = update.cloudTasks != nil
            if let rows = update.hosts {
                hosts = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                hasHostCatalog = true; hostFetchAt = update.fetchedAt
            }
            if let rows = update.cloudTasks { cloudTasks = rows; cloudFetchAt = update.fetchedAt }
            cachedChats = (try? DesktopTaskCatalog(codexHome: home, accountID: update.accountID).chatTasks(accountID: update.accountID)) ?? []
        case .failure(let error):
            onlineMessage = error.message; cloudAvailable = false; hostsAvailable = false
            if case .authentication = error {
                accountID = nil; cloudTasks = []; cachedChats = []; hosts = [:]; hasHostCatalog = false
            }
        }
        rebuildTasks()
    }
    var usageText: String { usageSnapshot?.label() ?? "—" }
    var usageHelp: String {
        guard let snapshot = usageSnapshot else { return usageMessage }
        guard snapshot.label() != nil else { return "额度信息已过期，点击刷新" }
        return snapshot.windows.map { "\($0.periodLabel)额度剩余 \($0.remainingPercent)%" }.joined(separator: "\n")
    }
    func refreshUsage(force: Bool = false) {
        guard showUsage, let usageReader, !usageLoading,
              force || Date().timeIntervalSince(lastUsageAttempt) >= 30 else { return }
        lastUsageAttempt = Date()
        usageFeedbackReset?.cancel()
        usageRefreshState = .loading
        if usageSnapshot == nil { usageMessage = "正在读取额度…" }
        usageReader.refresh { [weak self] result in
            DispatchQueue.main.async {
                self?.completeUsageRefresh(result)
            }
        }
    }
    func completeUsageRefresh(_ result: Result<UsageSnapshot, UsageReadError>) {
        usageFeedbackReset?.cancel()
        switch result {
        case .success(let snapshot):
            usageSnapshot = snapshot
            usageRefreshState = .success
        case .failure(let error):
            usageSnapshot = nil
            usageMessage = error.message
            usageRefreshState = .failure
        }
        onStatusChange?()
        let reset = DispatchWorkItem { [weak self] in
            guard let self, !self.usageLoading else { return }
            self.usageRefreshState = .idle
        }
        usageFeedbackReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: reset)
    }
    func setShowUsage(_ visible: Bool) {
        showUsage = visible
        UserDefaults.standard.set(visible, forKey: "showUsage")
        if visible { refreshUsage(force: true) }
        onStatusChange?()
    }
    func apply(_ update: BridgeUpdate) {
        lastBridge = update
        rebuildTasks()
    }
    func rebuildTasks(now: Date = Date()) {
        let previousHeight = bodyHeight
        let cloudFresh = cloudAvailable && now.timeIntervalSince(cloudFetchAt) < 90
        let hostsFresh = hostsAvailable && now.timeIntervalSince(hostFetchAt) < 90
        var merged = lastBridge.tasks.compactMap { row -> IslandTask? in
            var row = row
            if case .remote(let id, let name) = row.source {
                if id.hasPrefix("remote-control:"), hasHostCatalog, hosts[id] == nil { return nil }
                if let host = hosts[id] {
                    row.source = .remote(hostID: id, name: host.name)
                    if hostsFresh && !host.online { row.invalidateStatus("主机离线 · 状态不可用") }
                } else { row.source = .remote(hostID: id, name: name) }
            }
            return row
        }
        merged += cloudTasks.map {
            var row = $0
            if !cloudFresh { row.invalidateStatus("云端状态已过期") }
            return row
        }
        merged += cachedChats
        merged.sort(by: IslandTask.precedes)
        if tasks != merged { tasks = merged }
        connected = lastBridge.connected || cloudFresh
        liveCount = lastBridge.liveCount
        connection = lastBridge.message; catalogAvailable = lastBridge.catalogAvailable || cloudFresh || !cachedChats.isEmpty
        var messages: [String] = []
        if let onlineMessage { messages.append(onlineMessage) }
        else {
            if !hostsFresh { messages.append("机器名称暂不可用，已知名称仅供参考") }
            if !cloudFresh { messages.append("Codex 云端状态暂不可用") }
        }
        if !cachedChats.isEmpty { messages.append("ChatGPT / Work 仅显示当前账户的缓存记录，无实时状态") }
        if sourceMessages != messages { sourceMessages = messages }
        if expanded && page == .tasks && bodyHeight != previousHeight { onLayoutChange?() }
        onStatusChange?()
    }
    var runningCount: Int { tasks.filter { $0.phase == .running }.count }
    var attentionCount: Int { tasks.filter { [.waiting, .failed].contains($0.phase) }.count }
    var newContentCount: Int { tasks.filter { $0.hasUnreadContent || $0.phase == .completed }.count }
    var priorityTasks: [IslandTask] { tasks.filter { $0.section != .recent } }
    var recentTasks: [IslandTask] { tasks.filter { $0.section == .recent } }
    var prioritySummary: String {
        var parts: [String] = []
        if attentionCount > 0 { parts.append("\(attentionCount) 待处理") }
        if runningCount > 0 { parts.append("\(runningCount) 进行中") }
        if newContentCount > 0 { parts.append("\(newContentCount) 有新内容") }
        return parts.isEmpty ? "当前没有待处理的更新" : parts.joined(separator: " · ")
    }
    var petPhase: TaskPhase {
        if attentionCount > 0 { return .waiting }
        if runningCount > 0 { return .running }
        return newContentCount > 0 ? .completed : .idle
    }
    var compactStatus: String {
        let total = priorityTasks.count
        if total > 0 { return "×\(total)" }
        return connected ? "就绪" : "离线"
    }
    var bodyHeight: CGFloat {
        if page == .settings { return 370 }
        if page == .chat { return 300 }
        let count = min(showRecentTasks ? tasks.count : priorityTasks.count, 4)
        return count == 0 ? 220 : CGFloat(count) * 60 + 150
    }
    func toggleRecentTasks() {
        pinned = true
        showRecentTasks.toggle()
        if showRecentTasks { presentedRecentTasks = true }
        onLayoutChange?()
    }
    func finishLayoutTransition() {
        resizingExpandedBody = false
        presentedRecentTasks = expanded && showRecentTasks
    }
    func expand(_ page: Page = .tasks, pin: Bool = true) {
        if !expanded { showRecentTasks = false; presentedRecentTasks = false }
        self.page = page; self.pinned = pin; expanded = true; feedback = nil; onLayoutChange?()
        if page == .tasks { refreshUsage() }
        if page == .chat { onFocusInput?() }
    }
    func collapse() {
        guard !modalOpen else { return }
        expanded = false; pinned = false; feedback = nil; onLayoutChange?()
    }
    func toggle() { expanded ? collapse() : expand() }
    func toggleFromHeader() {
        if expanded && !pinned { pinned = true }
        else { toggle() }
    }
    func saveAppearance() {
        UserDefaults.standard.set(floating, forKey: "floating")
        UserDefaults.standard.set(selectedScreen, forKey: "displayID")
        onLayoutChange?()
    }
    func reloadPets() {
        library.reload(); pets = library.pets
        if !pets.contains(where: { $0.id == selectedPet }) { selectedPet = pets.first?.id ?? "none" }
        selectPet()
    }
    func selectPet() {
        petImage = library.image(for: selectedPet)
        UserDefaults.standard.set(selectedPet, forKey: "petID")
        if !pets.isEmpty && petImage == nil { feedback = "宠物图片无法读取，已使用默认图标" }
    }
    func importPet() {
        modalOpen = true
        let panel = NSOpenPanel()
        panel.title = "选择自定义宠物的 pet.json"
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self else { return }
            self.modalOpen = false
            guard response == .OK, let url = panel.url else { return }
            guard let pet = PetLibrary.customPet(manifest: url) else {
                self.feedback = "无法读取宠物，请选择包含有效精灵图的 pet.json"; return
            }
            UserDefaults.standard.set(url.path, forKey: "importedPetManifest")
            self.selectedPet = pet.id; self.reloadPets()
        }
    }
    func setLaunchAtLogin(_ enable: Bool) {
        do {
            if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                feedback = "请在系统设置的登录项中允许 Codex Island"
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { launchAtLogin = SMAppService.mainApp.status == .enabled; feedback = "登录项未能更新，请在系统设置中检查" }
    }
    func open(_ url: URL) {
        guard PetLibrary.codexApplication() != nil else { feedback = "未找到 Codex 客户端，请先安装并打开 Codex"; return }
        if NSWorkspace.shared.open(url) { collapse() }
        else { feedback = "未能打开 Codex，请从菜单栏重试" }
    }
    func openTask(_ task: IslandTask) {
        if task.source.hostID != nil,
           Set(tasks.filter { $0.threadID == task.threadID }.compactMap { $0.source.hostID }).count > 1 {
            feedback = "任务存在于多台机器，请在 Codex 中选择「\(task.source.label)」"
            if let app = PetLibrary.codexApplication() { NSWorkspace.shared.open(app) }
        } else if let url = CodexLink.task(task) { open(url) }
    }
    func sendPrompt() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.utf8.count <= 8000 else { feedback = "这段内容较长，请在 Codex 中继续输入"; return }
        let wasExpanded = expanded
        open(CodexLink.newThread(prompt: text))
        if wasExpanded && !expanded { prompt = "" }
    }
}
