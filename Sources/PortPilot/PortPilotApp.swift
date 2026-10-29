import AppKit
import ServiceManagement
import SwiftUI

@main
struct PortPilotMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        try? SMAppService.mainApp.register()
        createStatusItem()
        showWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◉"

        let menu = NSMenu()
        menu.addItem(withTitle: "显示 PortPilot", action: #selector(showWindowFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 PortPilot", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func showWindowFromMenu() {
        showWindow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = PortPilotView()
        let hostingView = NSHostingView(rootView: contentView)
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 340, height: 460)
        let origin = NSPoint(
            x: visibleFrame.maxX - size.width - 18,
            y: visibleFrame.maxY - size.height - 18
        )

        let newWindow = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "PortPilot"
        newWindow.titleVisibility = .hidden
        newWindow.titlebarAppearsTransparent = true
        newWindow.isMovableByWindowBackground = true
        newWindow.level = .floating
        newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newWindow.minSize = NSSize(width: 300, height: 360)
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.hasShadow = true
        newWindow.contentView = hostingView
        newWindow.makeKeyAndOrderFront(nil)
        window = newWindow
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum PortProtocol: String, Codable, CaseIterable {
    case tcp = "TCP"
    case udp = "UDP"
}

struct DetectedPort: Identifiable, Hashable {
    let id: String
    let port: Int
    let transport: PortProtocol
    let address: String
    let process: String
    let pid: Int
    let user: String
}

struct CommandRule: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var port: Int
    var command: String
    var workingDirectory: String
}

@MainActor
final class PortMonitor: ObservableObject {
    @Published private(set) var ports: [DetectedPort] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?

    private var timer: Timer?
    private var monitoredPorts = Set<Int>()

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    deinit {
        timer?.invalidate()
    }

    func updateMonitoredPorts(_ ports: Set<Int>) {
        monitoredPorts = ports
        refresh()
    }

    func refresh() {
        guard !monitoredPorts.isEmpty else {
            ports = []
            lastUpdated = Date()
            errorMessage = nil
            return
        }

        let portArguments = monitoredPorts.sorted()
        let tcpArguments = ["-nP", "-sTCP:LISTEN"] + portArguments.map { "-iTCP:\($0)" }
        let udpArguments = ["-nP"] + portArguments.map { "-iUDP:\($0)" }
        let tcpOutput = runLsof(arguments: tcpArguments)
        let udpOutput = runLsof(arguments: udpArguments)
        let parsed = parse(tcpOutput, transport: .tcp) + parse(udpOutput, transport: .udp)
        ports = Dictionary(grouping: parsed, by: \.id).compactMap(\.value.first)
            .sorted { lhs, rhs in
                if lhs.port == rhs.port { return lhs.transport.rawValue < rhs.transport.rawValue }
                return lhs.port < rhs.port
            }
        lastUpdated = Date()
        errorMessage = nil
    }

    private func runLsof(arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            errorMessage = error.localizedDescription
            return ""
        }
    }

    private func parse(_ output: String, transport: PortProtocol) -> [DetectedPort] {
        output.split(separator: "\n").compactMap { line in
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 9, columns[0] != "COMMAND", let pid = Int(columns[1]) else { return nil }
            let endpoint = String(columns[8]).replacingOccurrences(of: " (LISTEN)", with: "")
            guard let port = endpoint.split(separator: ":").last.flatMap({ Int($0) }) else { return nil }
            let cleanAddress = String(endpoint.dropLast(String(port).count + 1))
            let process = String(columns[0])
            let user = String(columns[2])
            let id = "\(transport.rawValue)-\(pid)-\(port)-\(endpoint)"
            return DetectedPort(id: id, port: port, transport: transport, address: cleanAddress, process: process, pid: pid, user: user)
        }
    }
}

@MainActor
final class CommandStore: ObservableObject {
    @Published var rules: [CommandRule] = [] {
        didSet { save() }
    }

    private let storageKey = "portpilot.command-rules"

    init() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([CommandRule].self, from: data) else { return }
        rules = decoded
    }

    func add(_ rule: CommandRule) {
        rules.append(rule)
    }

    func remove(_ rule: CommandRule) {
        rules.removeAll { $0.id == rule.id }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

enum CommandLauncher {
    static func launch(_ rule: CommandRule) throws {
        let command = rule.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? rule.command
            : "cd \(shellQuote(rule.workingDirectory)) && \(rule.command)"
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "; ")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            throw NSError(domain: "PortPilot", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 Terminal 启动脚本"])
        }
        appleScript.executeAndReturnError(&error)
        if let error {
            throw NSError(domain: "PortPilot", code: 2, userInfo: [NSLocalizedDescriptionKey: error.description])
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct PortPilotView: View {
    @StateObject private var monitor = PortMonitor()
    @StateObject private var commandStore = CommandStore()
    @State private var selectedTab = 0
    @State private var showingEditor = false
    @State private var launchError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("视图", selection: $selectedTab) {
                Text("监听端口").tag(0)
                Text("启动指令").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            if selectedTab == 0 {
                portsView
            } else {
                commandsView
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear {
            monitor.updateMonitoredPorts(configuredPorts)
        }
        .onChange(of: commandStore.rules) { _ in
            monitor.updateMonitoredPorts(configuredPorts)
        }
        .alert("启动失败", isPresented: Binding(
            get: { launchError != nil },
            set: { if !$0 { launchError = nil } }
        )) {
            Button("好") { launchError = nil }
        } message: {
            Text(launchError ?? "未知错误")
        }
        .sheet(isPresented: $showingEditor) {
            CommandEditorView { rule in
                commandStore.add(rule)
                showingEditor = false
            } onCancel: {
                showingEditor = false
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("PortPilot")
                    .font(.title2.weight(.semibold))
                Text("本机端口与开发服务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                monitor.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("立即刷新")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var portsView: some View {
        let developmentPorts = monitor.ports.filter { configuredPorts.contains($0.port) }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("开发端口", systemImage: "dot.radiowaves.left.and.right")
                    .font(.subheadline.weight(.medium))
                Text("\(developmentPorts.count) 个端口")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let lastUpdated = monitor.lastUpdated {
                    Text(lastUpdated, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)

            if developmentPorts.isEmpty {
                let message = configuredPorts.isEmpty
                    ? "请到“启动指令”添加要监控的开发端口"
                    : "已配置端口当前没有运行中的服务"
                EmptyStateView(title: "暂无运行中的开发端口", systemImage: "network.slash", description: message)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(developmentPorts) { port in
                            PortRow(port: port, rule: commandStore.rules.first(where: { $0.port == port.port })) { rule in
                                launch(rule)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private var commandsView: some View {
        VStack(spacing: 8) {
            HStack {
                Text("自定义启动指令")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    showingEditor = true
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)

            if commandStore.rules.isEmpty {
                EmptyStateView(title: "还没有启动指令", systemImage: "terminal", description: "为常用开发服务绑定端口和命令")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(commandStore.rules) { rule in
                            CommandRow(rule: rule, isRunning: monitor.ports.contains(where: { $0.port == rule.port })) {
                                launch(rule)
                            } onDelete: {
                                commandStore.remove(rule)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func launch(_ rule: CommandRule) {
        do {
            try CommandLauncher.launch(rule)
        } catch {
            launchError = error.localizedDescription
        }
    }

    private var configuredPorts: Set<Int> {
        Set(commandStore.rules.map(\.port))
    }
}

struct PortRow: View {
    let port: DetectedPort
    let rule: CommandRule?
    let onLaunch: (CommandRule) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("\(port.port)")
                    .font(.title3.monospacedDigit().weight(.bold))
                Text(port.transport.rawValue)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(port.transport == .tcp ? .blue : .orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background((port.transport == .tcp ? Color.blue : Color.orange).opacity(0.13), in: Capsule())
                Spacer()
                if let rule {
                    Button("启动") { onLaunch(rule) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "app.fill")
                Text(port.process)
                Text("PID \(port.pid)")
                Spacer()
                Text(port.address)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let rule {
                Label(rule.name, systemImage: "link")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct CommandRow: View {
    let rule: CommandRule
    let isRunning: Bool
    let onLaunch: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isRunning ? "checkmark.circle.fill" : "terminal.fill")
                .foregroundStyle(isRunning ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(rule.name).font(.headline)
                    Text(":\(rule.port)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if isRunning { Text("运行中").font(.caption2).foregroundStyle(.green) }
                }
                Text(rule.command)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                if !rule.workingDirectory.isEmpty {
                    Text(rule.workingDirectory)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(spacing: 4) {
                Button("启动", action: onLaunch)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CommandEditorView: View {
    @State private var name = ""
    @State private var port = ""
    @State private var command = ""
    @State private var workingDirectory = ""
    let onSave: (CommandRule) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加启动指令")
                .font(.title3.weight(.semibold))
            TextField("名称，例如：国内 Web", text: $name)
            TextField("端口，例如：3000", text: $port)
                .textFieldStyle(.roundedBorder)
            TextField("命令，例如：pnpm dev", text: $command)
                .textFieldStyle(.roundedBorder)
            TextField("工作目录（可选）", text: $workingDirectory)
                .textFieldStyle(.roundedBorder)
            Text("命令会在新的 Terminal 窗口中执行。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("保存") {
                    guard let portNumber = Int(port), portNumber > 0, !name.isEmpty, !command.isEmpty else { return }
                    onSave(CommandRule(name: name, port: portNumber, command: command, workingDirectory: workingDirectory))
                }
                .buttonStyle(.borderedProminent)
                .disabled(Int(port) == nil || name.isEmpty || command.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 360)
    }
}
