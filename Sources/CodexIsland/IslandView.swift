import SwiftUI
import IslandCore

struct IslandView: View {
    @ObservedObject var model: IslandModel
    let hover: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var inputFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let progress = min(1, max(0, (geometry.size.height - model.layout.headerHeight) / max(1, model.presentationBodyHeight)))
            VStack(spacing: 0) {
                header
                if model.presentationBodyHeight > 0 {
                    VStack(spacing: 0) {
                        switch model.page {
                        case .tasks: taskList
                        case .chat: chat
                        case .settings: settings
                        }
                    }
                    .frame(height: model.resizingExpandedBody
                           ? max(0, geometry.size.height - model.layout.headerHeight)
                           : model.presentationBodyHeight)
                    .allowsHitTesting(model.expanded)
                    .accessibilityHidden(!model.expanded)
                }
            }
            // The window and its contents share one frame clock, including in-place list resizing.
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .background(Color.black)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: model.layout.attached ? 0 : 24,
                                              bottomLeadingRadius: 22 + 6 * progress,
                                              bottomTrailingRadius: 22 + 6 * progress,
                                              topTrailingRadius: model.layout.attached ? 0 : 24))
            .overlay(alignment: .bottom) {
                if let feedback = model.feedback {
                    Text(feedback).font(.system(size: 12)).foregroundStyle(.white)
                        .padding(12).frame(maxWidth: .infinity).background(.black.opacity(0.96))
                        .clipShape(RoundedRectangle(cornerRadius: 16)).padding(10)
                        .accessibilityAddTraits(.updatesFrequently)
                        .onTapGesture { model.feedback = nil }
                }
            }
            .onHover(perform: hover)
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onChange(of: model.page) { _, page in inputFocused = page == .chat }
        .onExitCommand { model.collapse() }
    }

    private var header: some View {
        let petHeight = min(32, max(0, model.layout.headerHeight - 4))
        return Button { model.toggleFromHeader() } label: {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    PetSprite(image: model.petImage, phase: model.petPhase, reduceMotion: reduceMotion)
                        .frame(width: petHeight * 30 / 32, height: petHeight)
                    if !model.layout.attached {
                        Text("Codex").font(.system(size: 12, weight: .medium))
                    }
                }
                .frame(maxWidth: .infinity)
                .clipped()
                if model.layout.notchReservation > 0 {
                    Color.clear.frame(width: model.layout.notchReservation).allowsHitTesting(false)
                } else { Spacer(minLength: 6) }
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 5, height: 5)
                    Text(model.compactStatus).lineLimit(1).minimumScaleFactor(0.8)
                        .font(.system(size: 11, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .clipped()
            }
            .padding(.horizontal, model.layout.attached ? 8 : 16)
            .frame(height: model.layout.headerHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.expanded ? (model.pinned ? "收起 Codex 灵动岛" : "固定展开 Codex 灵动岛") : "展开 Codex 灵动岛，\(model.prioritySummary)")
    }
    private var statusColor: Color {
        if !model.connected { return .gray }
        if model.hasPendingCoverage || (!model.expanded && !model.priorityTasks.isEmpty) { return .yellow }
        return model.attentionCount > 0 ? .orange : Color(red: 0.6, green: 0.9, blue: 0.74)
    }

    private var taskList: some View {
        VStack(spacing: 12) {
            HStack {
                Text("当前动态").font(.system(size: 12, weight: .medium))
                Spacer()
                if model.showUsage {
                    HStack(spacing: 6) {
                        Text(model.usageText).monospacedDigit().foregroundStyle(.secondary)
                            .help(model.usageHelp).accessibilityLabel(model.usageHelp)
                        Button { model.refreshUsage(force: true) } label: {
                            Group {
                                switch model.usageRefreshState {
                                case .loading:
                                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .rotationEffect(.degrees(reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360))
                                    }.transition(.identity)
                                case .success:
                                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.mint)
                                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                                case .failure:
                                    Image(systemName: "exclamationmark").foregroundStyle(.orange)
                                case .idle:
                                    Image(systemName: "arrow.clockwise")
                                }
                            }.frame(width: 16, height: 16)
                                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.65), value: model.usageRefreshState)
                        }
                        .buttonStyle(.plain).disabled(model.usageLoading)
                        .help(model.usageRefreshHelp).accessibilityLabel(model.usageRefreshHelp)
                    }.font(.system(size: 11))
                }
            }
            if !model.priorityTasks.isEmpty || model.hasPendingCoverage {
                Text(model.prioritySummary).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.priorityTasks.isEmpty && model.pendingTasks.isEmpty && !model.presentedRecentTasks {
                VStack(spacing: 10) {
                    Image(systemName: model.catalogAvailable ? "bubble.left" : "link").font(.system(size: 23)).foregroundStyle(.secondary)
                    Text(model.hasPendingCoverage ? "部分来源的活动状态尚未确认" : !model.connected ? "连接恢复后显示实时动态" : !model.catalogAvailable ? "先打开 Codex，即可查看任务" : model.tasks.isEmpty ? "从一句话开始" : "暂时没有进行中或待查看的内容").font(.system(size: 13))
                    Text(model.connection).font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.priorityTasks) { task in
                            Button { model.openTask(task) } label: { taskRow(task) }.buttonStyle(TaskButtonStyle())
                                .accessibilityLabel("\(task.title)，\(task.source.label)，\(task.displayStatus)，打开对话")
                        }
                        if !model.pendingTasks.isEmpty {
                            Text("状态待同步 · 未计入重点数量").font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                            ForEach(model.pendingTasks) { task in
                                Button { model.openTask(task) } label: { taskRow(task) }.buttonStyle(TaskButtonStyle())
                                    .accessibilityLabel("\(task.title)，\(task.source.label)，\(task.displayStatus)，未计入重点数量，打开对话")
                            }
                        }
                        if model.presentedRecentTasks {
                            Text("最近任务").font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4).padding(.bottom, 2)
                            ForEach(model.recentTasks) { task in
                                Button { model.openTask(task) } label: { taskRow(task) }.buttonStyle(TaskButtonStyle())
                                    .accessibilityLabel("\(task.title)，\(task.source.label)，\(task.displayStatus)，打开对话")
                            }
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            if !model.recentTasks.isEmpty {
                Button {
                    model.toggleRecentTasks()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.showRecentTasks ? "chevron.up" : "chevron.down")
                        Text(model.showRecentTasks ? "收起最近任务" : "查看最近任务（\(model.recentTasks.count)）")
                        Spacer()
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Button { model.expand(.chat) } label: { Label("新对话", systemImage: "plus").frame(maxWidth: .infinity) }
                    .buttonStyle(IslandButtonStyle(primary: true))
                Button { model.expand(.settings) } label: { Image(systemName: "gearshape").frame(width: 24) }
                    .buttonStyle(IslandButtonStyle()).accessibilityLabel("灵动岛设置")
            }
        }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 16)
    }
    private func taskRow(_ task: IslandTask) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(task.phase)).font(.system(size: 14)).foregroundStyle(color(task.phase)).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if task.hasUnreadContent || task.phase == .completed {
                        Text("新").font(.system(size: 10, weight: .medium)).foregroundStyle(.mint)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(.mint.opacity(0.12), in: Capsule())
                    }
                    Spacer(minLength: 0)
                    Label(task.source.label, systemImage: task.source.symbol)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 130, alignment: .trailing).layoutPriority(1)
                }
                Text([task.displayStatus, task.projectName].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .help([task.title, task.source.label, task.displayStatus, task.cwd].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    private var chat: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageHeader("快捷对话")
            Text("想让 Codex 做什么？").font(.system(size: 18, weight: .medium))
            TextField("输入一句话…", text: $model.prompt, axis: .vertical)
                .font(.system(size: 14)).lineLimit(3...5).textFieldStyle(.plain)
                .padding(12).background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .focused($inputFocused).onSubmit { model.sendPrompt() }
            Text("完整对话将在 Codex 中继续").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button { model.sendPrompt() } label: { Label("在 Codex 中继续", systemImage: "arrow.up.right").frame(maxWidth: .infinity) }
                .buttonStyle(IslandButtonStyle(primary: true))
                .disabled(model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(18)
        .onAppear {
            inputFocused = true
            model.onFocusInput?()
        }
    }

    private var settings: some View {
        VStack(spacing: 12) {
            pageHeader("灵动岛设置")
            ScrollView {
                VStack(spacing: 12) {
                    HStack {
                        Text("宠物")
                        Spacer()
                        Picker("宠物", selection: $model.selectedPet) {
                            ForEach(model.pets) { Text($0.name).tag($0.id) }
                        }.labelsHidden().frame(maxWidth: 170)
                            .onChange(of: model.selectedPet) { _, _ in model.selectPet() }
                        Button { model.importPet() } label: { Image(systemName: "folder.badge.plus") }.help("导入 pet.json")
                    }
                    HStack {
                        Text("显示位置")
                        Spacer()
                        Picker("显示位置", selection: $model.selectedScreen) {
                            Text("自动 · 优先内置屏幕").tag("auto")
                            ForEach(model.screens, id: \.id) { Text($0.name).tag($0.id) }
                        }.labelsHidden().frame(maxWidth: 210)
                            .onChange(of: model.selectedScreen) { _, _ in model.saveAppearance() }
                    }
                    Toggle(isOn: Binding(get: { model.showUsage }, set: { model.setShowUsage($0) })) {
                        Text("显示额度").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Toggle(isOn: $model.floating) { Text("悬浮胶囊").frame(maxWidth: .infinity, alignment: .leading) }
                        .onChange(of: model.floating) { _, _ in model.saveAppearance() }
                    Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                        Text("登录时启动").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    HStack {
                        Text(model.liveCount > 0 ? "客户端实时状态 · \(model.liveCount) 个任务" : model.connection)
                        Spacer()
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(model.sourceMessages, id: \.self) { message in
                        Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if model.shortcutAvailable { Text("⌃⌥I 随时展开或收起").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                }.font(.system(size: 12)).toggleStyle(IslandToggleStyle()).controlSize(.small)
            }.scrollIndicators(.hidden)
            Button { model.open(CodexLink.settings) } label: { Label("打开 Codex 设置", systemImage: "arrow.up.right").frame(maxWidth: .infinity) }
                .buttonStyle(IslandButtonStyle())
        }.padding(18)
    }
    private func pageHeader(_ title: String) -> some View {
        HStack {
            Button { model.expand(.tasks) } label: { Label("任务", systemImage: "chevron.left") }.buttonStyle(.plain)
            Spacer()
            Text(title).foregroundStyle(.secondary)
        }.font(.system(size: 12))
    }
    private func icon(_ phase: TaskPhase) -> String {
        switch phase {
        case .running: return "circle.dotted"
        case .waiting: return "hand.raised.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: return "bubble.left"
        case .unknown: return "clock"
        }
    }
    private func color(_ phase: TaskPhase) -> Color {
        switch phase {
        case .running, .completed: return Color(red: 0.6, green: 0.9, blue: 0.74)
        case .waiting: return .orange
        case .failed: return .red
        default: return .gray
        }
    }
}

private struct IslandToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 8)
                Capsule()
                    .fill(configuration.isOn
                          ? Color(red: 0.43, green: 0.83, blue: 0.66)
                          : Color(red: 0.38, green: 0.40, blue: 0.46))
                    .frame(width: 38, height: 22)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 16, height: 16)
                            .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                            .padding(.horizontal, 3)
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: configuration.isOn)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

private struct TaskButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.065), in: RoundedRectangle(cornerRadius: 12))
    }
}
private struct IslandButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).padding(.vertical, 11).padding(.horizontal, 12)
            .foregroundStyle(primary ? Color.black : Color.white)
            .background(primary ? Color.white.opacity(0.93) : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.75 : 1)
    }
}

private struct PetSprite: View {
    let image: CGImage?
    let phase: TaskPhase
    let reduceMotion: Bool
    var body: some View {
        if let image {
            TimelineView(.animation(minimumInterval: phase == .idle ? 0.65 : 0.15, paused: reduceMotion)) { timeline in
                let row = phase == .running ? 7 : phase == .waiting ? 6 : phase == .failed ? 5 : phase == .completed ? 3 : 0
                let count = row == 3 ? 4 : row == 5 ? 8 : 6
                let column = reduceMotion ? 0 : Int(timeline.date.timeIntervalSinceReferenceDate / (phase == .idle ? 0.65 : 0.15)) % count
                if let frame = image.cropping(to: CGRect(x: column * 192, y: row * 208, width: 192, height: 208)) {
                    Image(decorative: frame, scale: 1).resizable().interpolation(.high).scaledToFit()
                }
            }.accessibilityHidden(true)
        } else {
            Image(systemName: "sparkle").font(.system(size: 20)).foregroundStyle(.mint).accessibilityHidden(true)
        }
    }
}
