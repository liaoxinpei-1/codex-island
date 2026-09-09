import AppKit
import SwiftUI
import IslandCore

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class PanelController {
    let panel: IslandPanel
    let model: IslandModel
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var hoverWork: DispatchWorkItem?
    private var frameTimer: Timer?
    private var presentedExpanded = false
    private var hoverExpansionSuppressed = false
    private var lastDiagnostic = Date.distantPast

    init(model: IslandModel) {
        self.model = model
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Codex Island"
        panel.identifier = NSUserInterfaceItemIdentifier("codex-island-panel")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        let hosting = NSHostingView(rootView: IslandView(model: model) { [weak self] hovering in self?.hover(hovering) })
        hosting.sizingOptions = []
        hosting.focusRingType = .none
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        model.onLayoutChange = { [weak self] in self?.relayout() }
        model.onFocusInput = { [weak self] in
            DispatchQueue.main.async { self?.focusEditor() }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.relayout(animated: false) }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.relayout(animated: false) }
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.model.expanded, !self.model.modalOpen else { return }
            if !self.panel.frame.contains(NSEvent.mouseLocation) { self.model.collapse() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.model.expanded == true { self?.model.collapse(); return nil }
            return event
        }
        relayout(animated: false)
    }

    private func focusEditor() {
        guard model.expanded, model.page == .chat else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.contentView?.layoutSubtreeIfNeeded()
        func editable(in view: NSView) -> NSView? {
            if let field = view as? NSTextField, field.isEditable, field.isEnabled { return field }
            if let text = view as? NSTextView, text.isEditable { return text }
            for child in view.subviews { if let match = editable(in: child) { return match } }
            return nil
        }
        if let content = panel.contentView, let editor = editable(in: content) {
            panel.makeFirstResponder(editor)
        }
    }

    static func displayID(_ screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "unknown"
    }
    static func geometry(_ screen: NSScreen) -> ScreenGeometry {
        let safeTop = screen.safeAreaInsets.top
        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea
        let width = safeTop > 0 ? (left != nil && right != nil ? max(0, right!.minX - left!.maxX) : 210) : 0
        let center = left != nil && right != nil ? (left!.maxX + right!.minX) / 2 : screen.frame.midX
        return ScreenGeometry(frame: screen.frame, visibleFrame: screen.visibleFrame,
                              safeTop: safeTop, notchWidth: width, notchCenterX: center)
    }
    private func chosenScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if model.selectedScreen != "auto", let match = screens.first(where: { Self.displayID($0) == model.selectedScreen }) { return match }
        return screens.first(where: { CGDisplayIsBuiltin(CGDirectDisplayID(UInt32(Self.displayID($0)) ?? 0)) != 0 })
            ?? NSScreen.main ?? screens.first
    }
    func relayout(animated: Bool = true) {
        guard let screen = chosenScreen() else { panel.orderOut(nil); return }
        let wasExpanded = presentedExpanded
        frameTimer?.invalidate()
        frameTimer = nil
        if presentedExpanded && !model.expanded {
            hoverWork?.cancel()
            hoverExpansionSuppressed = pointerInside()
        }
        presentedExpanded = model.expanded
        model.screens = NSScreen.screens.map { (Self.displayID($0), $0.localizedName) }
        model.layout = IslandLayout.calculate(screen: Self.geometry(screen), expanded: model.expanded,
                                              floating: model.floating, bodyHeight: model.bodyHeight)
        let animate = animated && panel.isVisible && panel.screen == screen && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // In-place resizing follows actual bounds; full open/close reveals or clips a stable page.
        model.resizingExpandedBody = animate && wasExpanded && model.expanded
        if model.expanded && !model.resizingExpandedBody {
            model.presentationBodyHeight = model.layout.bodyFrame.height
        } else if !model.expanded && wasExpanded {
            model.presentationBodyHeight = max(0, panel.frame.height - model.layout.headerHeight)
        }
        let target = model.layout.frame
        if animate && panel.frame != target {
            let transition = PanelFrameTransition(from: panel.frame, to: target)
            let started = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 1.0 / Double(min(120, screen.maximumFramesPerSecond)), repeats: true) { [weak self] timer in
                // This timer runs only on RunLoop.main; keep each frame update synchronous.
                MainActor.assumeIsolated {
                    guard let self else { timer.invalidate(); return }
                    let progress = (ProcessInfo.processInfo.systemUptime - started) / 0.22
                    self.applyFrame(transition.frame(at: progress))
                    if progress >= 1 {
                        timer.invalidate()
                        self.frameTimer = nil
                        self.finishTransition()
                    }
                }
            }
            frameTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            applyFrame(target)
            finishTransition()
        }
        panel.orderFrontRegardless()
        if !model.expanded && panel.isKeyWindow { panel.resignKey() }
        writeDiagnostics(force: true)
    }
    private func applyFrame(_ frame: CGRect) {
        panel.disableScreenUpdatesUntilFlush()
        panel.setFrame(frame, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }
    private func finishTransition() {
        if model.expanded { model.presentationBodyHeight = model.layout.bodyFrame.height }
        model.finishLayoutTransition()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        writeDiagnostics(force: true)
    }
    private func pointerInside() -> Bool {
        panel.isVisible && panel.frame.contains(NSEvent.mouseLocation)
    }
    private func hover(_ hovering: Bool) {
        hoverWork?.cancel()
        // Resizing can synthesize an exit/entry without the pointer actually leaving.
        // A deliberate collapse must stay closed until a real pointer exit.
        if !hovering && !pointerInside() { hoverExpansionSuppressed = false }
        if hovering && !model.expanded && !hoverExpansionSuppressed {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.model.expanded, !self.model.modalOpen, !self.hoverExpansionSuppressed,
                      self.pointerInside() else { return }
                self.model.expand(.tasks, pin: false)
            }
            hoverWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
        } else if !hovering && model.expanded && !model.pinned {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.expanded, !self.model.pinned, !self.model.modalOpen,
                      !self.pointerInside() else { return }
                self.model.collapse()
            }
            hoverWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }
    func cleanup() {
        hoverWork?.cancel()
        frameTimer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        panel.orderOut(nil)
    }
    func diagnostics() -> [String: Any] {
        func rect(_ r: CGRect) -> [String: Double] { ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height] }
        let layout = model.layout
        let screen = chosenScreen().map(Self.geometry)
        return [
            "appVersion": "0.1.23", "connected": model.connected, "liveTaskCount": model.liveCount,
            "catalogCount": model.tasks.count, "runningCount": model.runningCount, "attentionCount": model.attentionCount,
            "priorityTaskCount": model.priorityTasks.count, "recentTaskCount": model.recentTasks.count,
            "usageRemaining": model.usageText,
            "usageWindowMinutes": model.usageSnapshot?.primary.durationMinutes ?? 0,
            "usageLoading": model.usageLoading,
            "showUsage": model.showUsage,
            "newContentCount": model.newContentCount, "recentTasksExpanded": model.showRecentTasks,
            "catalogAvailable": model.catalogAvailable, "connectionMessage": model.connection,
            "expanded": model.expanded, "attachedToNotch": layout.attached, "windowLevel": panel.level.rawValue,
            "panelVisible": panel.isVisible, "panelFrame": rect(panel.frame), "targetFrame": rect(layout.frame),
            "presentationMode": layout.attached ? "notch" : "floating",
            "bodyFrame": rect(layout.bodyFrame), "notchReservation": layout.notchReservation,
            "headerHeight": layout.headerHeight, "safeTop": screen?.safeTop ?? 0,
            "screenFrame": screen.map { rect($0.frame) } ?? [:],
            "visibleFrame": screen.map { rect($0.visibleFrame) } ?? [:],
            "petLoaded": model.petImage != nil, "petCount": model.pets.count,
            "shortcutAvailable": model.shortcutAvailable,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
    }
    func writeDiagnostics(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastDiagnostic) > 5 else { return }
        lastDiagnostic = Date()
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexIsland")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: diagnostics(), options: [.prettyPrinted, .sortedKeys])
            try data.write(to: folder.appendingPathComponent("diagnostics.json"), options: .atomic)
        } catch { /* Diagnostics must not interrupt the visible app. */ }
    }
}
