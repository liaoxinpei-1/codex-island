import AppKit
import Carbon
import IslandCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: IslandModel!
    private var controller: PanelController!
    private var statusItem: NSStatusItem!
    private var summaryItem: NSMenuItem!
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        model = IslandModel(home: home)
        controller = PanelController(model: model)
        makeMenu()
        model.onStatusChange = { [weak self] in
            guard let self else { return }
            let summary = self.model.connected ? self.model.prioritySummary : self.model.connection
            self.summaryItem.title = summary
            self.statusItem.button?.toolTip = "Codex Island · \(summary)"
            self.controller.writeDiagnostics()
        }
        registerShortcut()
        model.start()
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.stop(); controller?.cleanup()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.expand(); return true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "codex-island" {
            DispatchQueue.main.async { [weak self] in
                switch url.host {
                case "settings": self?.model?.expand(.settings)
                case "chat": self?.model?.expand(.chat)
                case "collapse": self?.model?.collapse()
                default: self?.model?.expand()
                }
            }
        }
    }
    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "codex-island"
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Codex Island")
        let menu = NSMenu()
        summaryItem = NSMenuItem(title: "正在连接 Codex…", action: nil, keyEquivalent: "")
        summaryItem.isEnabled = false; menu.addItem(summaryItem)
        menu.addItem(.separator())
        func add(_ title: String, _ selector: Selector, key: String = "") {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self; menu.addItem(item)
        }
        add("展开灵动岛", #selector(showIsland))
        add("新对话…", #selector(newChat))
        add("灵动岛设置…", #selector(showSettings))
        add("打开 Codex 设置…", #selector(codexSettings))
        menu.addItem(.separator())
        add("恢复默认位置", #selector(resetPosition))
        menu.addItem(.separator())
        add("退出 Codex Island", #selector(quit), key: "q")
        statusItem.menu = menu
    }
    private func registerShortcut() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { delegate.model.toggle() }
            return noErr
        }, 1, &event, context, &hotKeyHandler)
        guard installed == noErr else { return }
        let id = EventHotKeyID(signature: 0x4349534C, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_I), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        model.shortcutAvailable = result == noErr
    }
    @objc private func showIsland() { model.expand() }
    @objc private func newChat() { model.expand(.chat) }
    @objc private func showSettings() { model.expand(.settings) }
    @objc private func codexSettings() { model.open(CodexLink.settings) }
    @objc private func resetPosition() {
        model.selectedScreen = "auto"; model.floating = false; model.saveAppearance(); model.expand()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
