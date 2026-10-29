import AppKit
import Carbon.HIToolbox
import Darwin
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
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var hotKeyHandler: EventHandlerUPP?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var lastHotKeyToggle = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        try? SMAppService.mainApp.register()
        createMainMenu()
        createStatusItem()
        registerGlobalHotKey()
        showWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◉"

        let menu = NSMenu()
        let toggleItem = menu.addItem(withTitle: "隐藏/显示 PortPilot", action: #selector(toggleWindowFromMenu), keyEquivalent: "p")
        toggleItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 PortPilot", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    private func createMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 PortPilot", action: #selector(quit), keyEquivalent: "q")
        appMenu.items.forEach { $0.target = self }
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func toggleWindowFromMenu() {
        toggleWindow()
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
        let size = NSSize(width: 340, height: 390)
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
        newWindow.isMovableByWindowBackground = false
        newWindow.level = .floating
        newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newWindow.minSize = NSSize(width: 300, height: 320)
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.hasShadow = true
        newWindow.contentView = hostingView
        newWindow.makeKeyAndOrderFront(nil)
        window = newWindow
        NSApp.activate(ignoringOtherApps: true)
    }

    private func toggleWindow() {
        guard let window else {
            showWindow()
            return
        }
        if window.isVisible {
            window.orderOut(nil)
        } else {
            showWindow()
        }
    }

    private func registerGlobalHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        hotKeyHandler = { _, _, _ in
            DispatchQueue.main.async {
                (NSApp.delegate as? AppDelegate)?.handleHotKey()
            }
            return noErr
        }
        guard let hotKeyHandler else { return }
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &eventType,
            nil,
            &hotKeyHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x50504C54), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_P),
            UInt32(optionKey | cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        registerNSEventFallback()
    }

    private func registerNSEventFallback() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == UInt16(kVK_ANSI_P) else { return }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == [.command, .option] else { return }
            self?.handleHotKey()
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return event
        }
    }

    private func handleHotKey() {
        let now = Date()
        guard now.timeIntervalSince(lastHotKeyToggle) > 0.25 else { return }
        lastHotKeyToggle = now
        toggleWindow()
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
    let socketID: String
    let pids: [Int]

    init(
        id: String,
        port: Int,
        transport: PortProtocol,
        address: String,
        process: String,
        pid: Int,
        user: String,
        socketID: String = "",
        pids: [Int] = []
    ) {
        self.id = id
        self.port = port
        self.transport = transport
        self.address = address
        self.process = process
        self.pid = pid
        self.user = user
        self.socketID = socketID
        self.pids = pids.isEmpty ? [pid] : pids
    }
}

struct CommandRule: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var port: Int?
    var command: String
    var workingDirectory: String
}

@MainActor
final class PortMonitor: ObservableObject {
    @Published private(set) var ports: [DetectedPort] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?

    private var timer: Timer?

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

    func refresh() {
        let tcpOutput = runLsof(arguments: ["-nP", "-iTCP", "-sTCP:LISTEN"])
        let udpOutput = runLsof(arguments: ["-nP", "-iUDP"])
        let parsed = parse(tcpOutput, transport: .tcp) + parse(udpOutput, transport: .udp)
        ports = Dictionary(grouping: parsed, by: \.id).values.compactMap(merge)
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
            let localEndpoint = endpoint.components(separatedBy: "->").first ?? endpoint
            guard let port = localEndpoint.split(separator: ":").last.flatMap({ Int($0) }) else { return nil }
            let cleanAddress = String(localEndpoint.dropLast(String(port).count + 1))
            let process = String(columns[0])
            let user = String(columns[2])
            let socketID = columns.count > 5 ? String(columns[5]) : "\(pid)-\(localEndpoint)"
            let id = "\(transport.rawValue)-\(socketID)-\(port)-\(localEndpoint)"
            return DetectedPort(
                id: id,
                port: port,
                transport: transport,
                address: cleanAddress,
                process: process,
                pid: pid,
                user: user,
                socketID: socketID
            )
        }
    }

    private func merge(_ group: [DetectedPort]) -> DetectedPort? {
        guard let representative = group.max(by: { $0.pid < $1.pid }) else { return nil }
        let pids = Array(Set(group.flatMap(\.pids))).sorted()
        return DetectedPort(
            id: representative.id,
            port: representative.port,
            transport: representative.transport,
            address: representative.address,
            process: representative.process,
            pid: representative.pid,
            user: representative.user,
            socketID: representative.socketID,
            pids: pids
        )
    }
}

enum DevelopmentPortDetector {
    static func category(for port: DetectedPort) -> String? {
        let process = port.process.lowercased()
        if port.port == 8011 && (process.hasPrefix("python") || process.hasPrefix("uvicorn")) {
            return "Prometheus 监控"
        }
        if process == "adb" || process.hasPrefix("adb-") { return "Android / ADB" }
        if process == "node" || process.hasPrefix("node-") { return "Node.js" }
        if process == "bun" || process.hasPrefix("bun-") { return "Bun" }
        if process == "deno" || process.hasPrefix("deno-") { return "Deno" }
        if process.hasPrefix("python") || process.hasPrefix("uvicorn") || process.hasPrefix("gunicorn") { return "Python" }
        if process.hasPrefix("ruby") || process.hasPrefix("puma") || process.hasPrefix("rails") { return "Ruby" }
        if process.hasPrefix("php") { return "PHP" }
        if process.hasPrefix("java") || process.hasPrefix("gradle") { return "Java" }
        if process.hasPrefix("webpack") || process.hasPrefix("vite") || process.hasPrefix("next") || process.hasPrefix("parcel") { return "前端构建工具" }
        if process.hasPrefix("cargo") || process.hasPrefix("rust") { return "Rust" }
        if process.hasPrefix("flutter") || process.hasPrefix("dart") { return "Flutter / Dart" }
        if process.hasPrefix("metro") || process.hasPrefix("expo") { return "React Native" }
        if process == "docker" || process.hasPrefix("docker-") || process.hasPrefix("com.docke") { return "Docker" }
        if process.hasPrefix("nginx") || process.hasPrefix("caddy") { return "Web Server" }
        return nil
    }

    static func isLikelyDevelopment(_ port: DetectedPort) -> Bool {
        category(for: port) != nil
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
        rules.removeAll { existing in
            existing.id == rule.id || (rule.port != nil && existing.port == rule.port)
        }
        rules.append(rule)
    }

    func assignPort(_ port: Int, to ruleID: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == ruleID }) else { return }
        rules[index].port = port
    }

    func remove(_ rule: CommandRule) {
        rules.removeAll { $0.id == rule.id }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

@MainActor
final class PortPreferences: ObservableObject {
    @Published private(set) var pinnedKeys: Set<String>
    @Published private(set) var orderKeys: [String]

    private let pinnedStorageKey = "portpilot.pinned-port-keys"
    private let orderStorageKey = "portpilot.port-order-keys"

    init() {
        pinnedKeys = Set(UserDefaults.standard.stringArray(forKey: pinnedStorageKey) ?? [])
        orderKeys = UserDefaults.standard.stringArray(forKey: orderStorageKey) ?? []
    }

    static func key(for port: DetectedPort) -> String {
        "\(port.transport.rawValue)-\(port.port)"
    }

    func isPinned(_ port: DetectedPort) -> Bool {
        pinnedKeys.contains(Self.key(for: port))
    }

    func pinnedTransport(for port: Int) -> PortProtocol? {
        if pinnedKeys.contains("TCP-\(port)") { return .tcp }
        if pinnedKeys.contains("UDP-\(port)") { return .udp }
        return nil
    }

    func togglePin(_ port: DetectedPort) {
        let key = Self.key(for: port)
        if pinnedKeys.contains(key) {
            pinnedKeys.remove(key)
        } else {
            pinnedKeys.insert(key)
        }
        save()
    }

    func ordered(_ ports: [DetectedPort]) -> [DetectedPort] {
        let positions = Dictionary(uniqueKeysWithValues: orderKeys.enumerated().map { ($1, $0) })
        return ports.sorted { lhs, rhs in
            let lhsKey = Self.key(for: lhs)
            let rhsKey = Self.key(for: rhs)
            let lhsPinned = pinnedKeys.contains(lhsKey)
            let rhsPinned = pinnedKeys.contains(rhsKey)
            if lhsPinned != rhsPinned { return lhsPinned }

            let lhsPosition = positions[lhsKey] ?? Int.max
            let rhsPosition = positions[rhsKey] ?? Int.max
            if lhsPosition != rhsPosition { return lhsPosition < rhsPosition }
            if lhs.port != rhs.port { return lhs.port < rhs.port }
            return lhs.transport.rawValue < rhs.transport.rawValue
        }
    }

    func move(_ sourceKey: String, before targetKey: String) {
        var updated = orderKeys
        if !updated.contains(sourceKey) { updated.append(sourceKey) }
        updated.removeAll { $0 == sourceKey }
        if let targetIndex = updated.firstIndex(of: targetKey) {
            updated.insert(sourceKey, at: targetIndex)
        } else {
            updated.append(sourceKey)
        }
        orderKeys = updated
        save()
    }

    private func save() {
        UserDefaults.standard.set(Array(pinnedKeys), forKey: pinnedStorageKey)
        UserDefaults.standard.set(orderKeys, forKey: orderStorageKey)
    }
}

enum PortTerminator {
    static func terminate(_ port: DetectedPort) throws {
        if port.process.lowercased().hasPrefix("com.docke") {
            try stopDockerContainers(for: port.port)
            return
        }

        for pid in port.pids {
            guard kill(pid_t(pid), SIGTERM) == 0 || errno == ESRCH else {
                let reason = String(cString: strerror(errno))
                throw NSError(
                    domain: "PortPilot",
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "无法终止 \(port.process)（PID \(pid)）：\(reason)"]
                )
            }
        }
    }

    static func impactDescription(for port: DetectedPort) -> String {
        if port.process.lowercased().hasPrefix("com.docke") {
            return "将停止映射到端口 \(port.port) 的 Docker 容器。"
        }
        let pidLabel = port.pids.count > 1
            ? port.pids.map(String.init).joined(separator: ", ")
            : String(port.pid)
        return "将向 \(port.process)（PID \(pidLabel)）发送终止信号；同一进程占用的其他端口也会一起停止。"
    }

    private static func stopDockerContainers(for port: Int) throws {
        guard let dockerPath = executablePath(for: "docker") else {
            throw NSError(domain: "PortPilot", code: 10, userInfo: [NSLocalizedDescriptionKey: "找不到 docker 命令，无法停止对应容器"])
        }

        let ids = try run(dockerPath, arguments: ["ps", "--filter", "publish=\(port)", "--format", "{{.ID}}"])
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !ids.isEmpty else {
            throw NSError(domain: "PortPilot", code: 11, userInfo: [NSLocalizedDescriptionKey: "没有找到映射到端口 \(port) 的运行中 Docker 容器"])
        }
        for id in ids {
            _ = try run(dockerPath, arguments: ["stop", id])
        }
    }

    private static func executablePath(for name: String) -> String? {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "命令执行失败"
            throw NSError(domain: "PortPilot", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

struct RuntimeFailure: Identifiable {
    let id = UUID()
    let ruleID: UUID
    let message: String
}

enum PortPilotAlert: Identifiable {
    case operationError(String)
    case termination(DetectedPort)
    case runtimeFailure(RuntimeFailure)

    var id: String {
        switch self {
        case .operationError(let message): return "operation-\(message)"
        case .termination(let port): return "termination-\(port.id)"
        case .runtimeFailure(let failure): return "runtime-\(failure.id.uuidString)"
        }
    }
}

@MainActor
final class CommandRuntime: ObservableObject {
    @Published private(set) var runningRuleIDs: Set<UUID> = []
    @Published private(set) var failedRuleIDs: Set<UUID> = []
    @Published private(set) var logs: [UUID: String] = [:]
    @Published var latestFailure: RuntimeFailure?
    private var processes: [UUID: Process] = [:]
    private var expectedStops: Set<UUID> = []

    func isRunning(_ ruleID: UUID) -> Bool {
        runningRuleIDs.contains(ruleID)
    }

    func log(for ruleID: UUID?) -> String {
        guard let ruleID else { return "" }
        return logs[ruleID] ?? ""
    }

    func start(_ rule: CommandRule) throws {
        guard !isRunning(rule.id) else { return }

        failedRuleIDs.remove(rule.id)
        expectedStops.remove(rule.id)
        logs[rule.id] = "[PortPilot] 启动命令：\(rule.command)\n"
        let command = rule.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? rule.command
            : "cd \(shellQuote(rule.workingDirectory)) && \(rule.command)"
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.appendFromPipe(data, ruleID: rule.id, label: nil)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.appendFromPipe(data, ruleID: rule.id, label: "错误")
            }
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task { @MainActor in
                self?.processDidExit(rule.id, name: rule.name, status: status)
            }
        }
        try process.run()
        processes[rule.id] = process
        runningRuleIDs.insert(rule.id)
    }

    func stop(_ rule: CommandRule, detectedPort: DetectedPort?) throws {
        var didStop = false

        if processes[rule.id] != nil {
            expectedStops.insert(rule.id)
        }

        if let detectedPort {
            do {
                try PortTerminator.terminate(detectedPort)
                didStop = true
            } catch where processes[rule.id] != nil {
                // The launched process below is still a valid fallback when the port owner exited first.
            }
        }

        if let process = processes.removeValue(forKey: rule.id) {
            if process.isRunning { process.terminate() }
            runningRuleIDs.remove(rule.id)
            didStop = true
        }

        guard didStop else {
            throw NSError(domain: "PortPilot", code: 20, userInfo: [NSLocalizedDescriptionKey: "没有找到可停止的运行进程"])
        }
    }

    private func appendFromPipe(_ data: Data, ruleID: UUID, label: String?) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        let prefix = label.map { "[\($0)] " } ?? ""
        appendLog(prefix + text, ruleID: ruleID)
    }

    private func appendLog(_ text: String, ruleID: UUID) {
        let maxCharacters = 60_000
        let updated = (logs[ruleID] ?? "") + text
        logs[ruleID] = updated.count > maxCharacters
            ? String(updated.suffix(maxCharacters))
            : updated
    }

    private func processDidExit(_ ruleID: UUID, name: String, status: Int32) {
        processes.removeValue(forKey: ruleID)
        runningRuleIDs.remove(ruleID)
        if expectedStops.remove(ruleID) != nil { return }
        guard status != 0 else { return }

        failedRuleIDs.insert(ruleID)
        let message = "“\(name)”启动命令已退出，状态码：\(status)。点击端口行可查看运行日志。"
        appendLog("\n[PortPilot] \(message)\n", ruleID: ruleID)
        latestFailure = RuntimeFailure(ruleID: ruleID, message: message)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct PortLogTarget: Identifiable {
    let id: String
    let port: DetectedPort
    let rule: CommandRule?

    init(port: DetectedPort, rule: CommandRule?) {
        self.port = port
        self.rule = rule
        let ruleKey = rule?.id.uuidString ?? "external"
        id = "\(port.id)-\(ruleKey)"
    }
}

struct RuntimeLogView: View {
    @ObservedObject var runtime: CommandRuntime
    let target: PortLogTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("端口 \(target.port.port) 运行日志")
                        .font(.headline)
                    Text(target.rule?.name ?? "\(target.port.process) · PID \(target.port.pid)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let rule = target.rule, runtime.failedRuleIDs.contains(rule.id) {
                    Label("启动失败", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button("关闭") { dismiss() }
            }

            if let rule = target.rule {
                Text(rule.command.isEmpty ? "仅监控端口" : rule.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            ScrollView {
                Text(logText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .frame(width: 520, height: 380)
    }

    private var logText: String {
        let log = runtime.log(for: target.rule?.id)
        if !log.isEmpty { return log }
        if target.rule == nil {
            return "该端口不是由 PortPilot 启动，无法读取外部进程已经产生的 stdout/stderr。\n\n当前可查看：进程、PID、协议和端口状态。"
        }
        return "暂无日志。\n\n只有由 PortPilot 启动的命令会捕获运行日志。"
    }
}

struct PortPilotView: View {
    @StateObject private var monitor = PortMonitor()
    @StateObject private var commandStore = CommandStore()
    @StateObject private var runtime = CommandRuntime()
    @StateObject private var preferences = PortPreferences()
    @State private var selectedTab = 0
    @State private var editorPreset: CommandRule?
    @State private var activeAlert: PortPilotAlert?
    @State private var logTarget: PortLogTarget?
    @State private var draggedPortKey: String?
    @State private var transitioningPortKeys: Set<String> = []
    @State private var transitioningRuleIDs: Set<UUID> = []

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
            monitor.refresh()
        }
        .onReceive(runtime.$latestFailure.compactMap { $0 }) { failure in
            activeAlert = .runtimeFailure(failure)
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .operationError(let message):
                return Alert(
                    title: Text("操作失败"),
                    message: Text(message),
                    dismissButton: .default(Text("好"))
                )
            case .termination(let port):
                return Alert(
                    title: Text("终止端口 \(port.port)？"),
                    message: Text(PortTerminator.impactDescription(for: port)),
                    primaryButton: .destructive(Text("终止")) {
                        terminate(port)
                    },
                    secondaryButton: .cancel()
                )
            case .runtimeFailure(let failure):
                return Alert(
                    title: Text("启动命令报错"),
                    message: Text(failure.message),
                    dismissButton: .default(Text("知道了"))
                )
            }
        }
        .sheet(item: $editorPreset) { preset in
            CommandEditorView(initialRule: preset) { rule in
                commandStore.add(rule)
                editorPreset = nil
            } onCancel: {
                editorPreset = nil
            }
        }
        .sheet(item: $logTarget) { target in
            RuntimeLogView(runtime: runtime, target: target)
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
        let developmentPorts = monitor.ports.filter {
            configuredPorts.contains($0.port) || DevelopmentPortDetector.isLikelyDevelopment($0)
        }
        let runningPortNumbers = Set(monitor.ports.map(\.port))
        let pinnedStoppedPorts = commandStore.rules.compactMap { rule -> DetectedPort? in
            guard let port = rule.port,
                  let transport = preferences.pinnedTransport(for: port),
                  !runningPortNumbers.contains(port) else { return nil }
            return DetectedPort(
                id: "configured-\(transport.rawValue)-\(port)",
                port: port,
                transport: transport,
                address: "",
                process: "未运行",
                pid: 0,
                user: ""
            )
        }
        let orderedPorts = preferences.ordered(developmentPorts + pinnedStoppedPorts)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("开发端口", systemImage: "dot.radiowaves.left.and.right")
                    .font(.subheadline.weight(.medium))
                Text("\(orderedPorts.count) 个端口")
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

            if orderedPorts.isEmpty {
                let message = configuredPorts.isEmpty
                    ? "未发现开发进程，可到“启动指令”添加端口"
                    : "已配置端口当前没有运行中的服务"
                EmptyStateView(title: "暂无运行中的开发端口", systemImage: "network.slash", description: message)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(orderedPorts) { port in
                            let detectedPort = monitor.ports.first(where: { $0.port == port.port })
                            let rule = commandStore.rules.first(where: { $0.port == Optional(port.port) })
                            PortRow(
                                port: port,
                                rule: rule,
                                autoDiscovered: !configuredPorts.contains(port.port),
                                isRunning: detectedPort != nil,
                                hasError: rule.map { runtime.failedRuleIDs.contains($0.id) } ?? false,
                                isTransitioning: transitioningPortKeys.contains(PortPreferences.key(for: port))
                                    || rule.map { transitioningRuleIDs.contains($0.id) } == true
                            ) {
                                editorPreset = rule
                                    ?? CommandRule(
                                        name: DevelopmentPortDetector.category(for: port) ?? "开发服务",
                                        port: port.port,
                                        command: "",
                                        workingDirectory: ""
                                    )
                            } onToggle: {
                                guard !transitioningPortKeys.contains(PortPreferences.key(for: port)) else { return }
                                if let rule {
                                    if let detectedPort {
                                        stop(rule, detectedPort: detectedPort)
                                    } else {
                                        launch(rule)
                                    }
                                } else {
                                    activeAlert = .termination(port)
                                }
                            } onTerminate: {
                                activeAlert = .termination(port)
                            } onShowLog: {
                                logTarget = PortLogTarget(port: port, rule: rule)
                            } onTogglePin: {
                                preferences.togglePin(port)
                            } isPinned: {
                                preferences.isPinned(port)
                            }
                            .onDrag {
                                let key = PortPreferences.key(for: port)
                                draggedPortKey = key
                                return NSItemProvider(object: key as NSString)
                            }
                            .onDrop(
                                of: [.text],
                                delegate: PortDropDelegate(
                                    targetKey: PortPreferences.key(for: port),
                                    draggedKey: $draggedPortKey,
                                    preferences: preferences
                                )
                            )
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
                    editorPreset = CommandRule(name: "", port: nil, command: "", workingDirectory: "")
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
                            let detectedPort = rule.port.flatMap { port in
                                monitor.ports.first(where: { $0.port == port })
                            }
                            CommandRow(
                                rule: rule,
                                isRunning: runtime.isRunning(rule.id) || detectedPort != nil,
                                hasError: runtime.failedRuleIDs.contains(rule.id),
                                isTransitioning: transitioningRuleIDs.contains(rule.id)
                            ) {
                                guard !transitioningRuleIDs.contains(rule.id) else { return }
                                if runtime.isRunning(rule.id) || detectedPort != nil {
                                    stop(rule, detectedPort: detectedPort)
                                } else {
                                    launch(rule)
                                }
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
        guard !transitioningRuleIDs.contains(rule.id) else { return }
        transitioningRuleIDs.insert(rule.id)
        let shouldAutoAssign = rule.port == nil
        let baselineKeys: Set<String>
        if shouldAutoAssign {
            monitor.refresh()
            baselineKeys = Set(monitor.ports.map(PortPreferences.key(for:)))
        } else {
            baselineKeys = []
        }

        do {
            try runtime.start(rule)
            finishRuleTransitionAfterDelay(rule.id)
            if shouldAutoAssign {
                watchForAutoAssignedPort(ruleID: rule.id, baselineKeys: baselineKeys)
            }
        } catch {
            transitioningRuleIDs.remove(rule.id)
            showError(error.localizedDescription)
        }
    }

    private func stop(_ rule: CommandRule, detectedPort: DetectedPort?) {
        guard !transitioningRuleIDs.contains(rule.id) else { return }
        transitioningRuleIDs.insert(rule.id)
        do {
            try runtime.stop(rule, detectedPort: detectedPort)
            waitForRuleStop(rule.id, port: detectedPort)
        } catch {
            transitioningRuleIDs.remove(rule.id)
            showError(error.localizedDescription)
        }
    }

    private func finishRuleTransitionAfterDelay(_ ruleID: UUID) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            transitioningRuleIDs.remove(ruleID)
        }
    }

    private func waitForRuleStop(_ ruleID: UUID, port: DetectedPort?) {
        Task { @MainActor in
            if let port {
                for _ in 0..<8 {
                    try? await Task.sleep(for: .milliseconds(250))
                    monitor.refresh()
                    let isStillOwned = monitor.ports.contains { isSameOwner($0, as: port) }
                    if !isStillOwned {
                        transitioningRuleIDs.remove(ruleID)
                        return
                    }
                }
                transitioningRuleIDs.remove(ruleID)
                showError("已发送停止信号，但端口 " + String(port.port) + " 仍被占用。")
            } else {
                try? await Task.sleep(for: .milliseconds(700))
                monitor.refresh()
                transitioningRuleIDs.remove(ruleID)
            }
        }
    }

    private func watchForAutoAssignedPort(ruleID: UUID, baselineKeys: Set<String>) {
        Task { @MainActor in
            for _ in 0..<15 {
                try? await Task.sleep(for: .seconds(1))
                monitor.refresh()
                let newPorts = monitor.ports.filter {
                    !baselineKeys.contains(PortPreferences.key(for: $0))
                        && DevelopmentPortDetector.isLikelyDevelopment($0)
                }
                if newPorts.count == 1 {
                    commandStore.assignPort(newPorts[0].port, to: ruleID)
                    return
                }
                if newPorts.count > 1 {
                    let ports = newPorts.map { String($0.port) }.joined(separator: ", ")
                    showError("启动后发现多个新开发端口（\(ports)），无法安全自动绑定，请编辑该指令填写端口。")
                    return
                }
            }
        }
    }

    private func terminate(_ port: DetectedPort) {
        let key = PortPreferences.key(for: port)
        guard !transitioningPortKeys.contains(key) else { return }
        transitioningPortKeys.insert(key)
        do {
            try PortTerminator.terminate(port)
            Task { @MainActor in
                for _ in 0..<8 {
                    try? await Task.sleep(for: .milliseconds(250))
                    monitor.refresh()
                    let isStillOwned = monitor.ports.contains { isSameOwner($0, as: port) }
                    if !isStillOwned {
                        transitioningPortKeys.remove(key)
                        return
                    }
                }
                transitioningPortKeys.remove(key)
                showError("已向 " + port.process + "（PID " + String(port.pid) + "）发送终止信号，但端口 " + String(port.port) + " 仍被占用。该进程可能忽略了 SIGTERM，请稍后重试或手动结束进程。")
            }
        } catch {
            transitioningPortKeys.remove(key)
            showError(error.localizedDescription)
        }
    }

    private func showError(_ message: String) {
        activeAlert = .operationError(message)
    }

    private func isSameOwner(_ current: DetectedPort, as original: DetectedPort) -> Bool {
        current.port == original.port
            && current.transport == original.transport
            && !Set(current.pids).isDisjoint(with: original.pids)
    }

    private var configuredPorts: Set<Int> {
        Set(commandStore.rules.compactMap(\.port))
    }
}

struct PortRow: View {
    let port: DetectedPort
    let rule: CommandRule?
    let autoDiscovered: Bool
    let isRunning: Bool
    let hasError: Bool
    let isTransitioning: Bool
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onTerminate: () -> Void
    let onShowLog: () -> Void
    let onTogglePin: () -> Void
    let isPinned: () -> Bool

    var body: some View {
        let processLabel = DevelopmentPortDetector.category(for: port) ?? port.process
        let pidLabel = port.pids.count > 1 ? "\(port.pid)+\(port.pids.count - 1)" : "\(port.pid)"
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("拖动排序")

            Button(action: onTogglePin) {
                Image(systemName: isPinned() ? "star.fill" : "star")
                    .foregroundStyle(isPinned() ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help(isPinned() ? "取消置顶" : "置顶端口")

            Button(action: onShowLog) {
                HStack(spacing: 5) {
                    Text("\(port.port)")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .frame(width: 42, alignment: .trailing)
                    Text(port.transport.rawValue)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(port.transport == .tcp ? .blue : .orange)

                    Text(rule?.name ?? DevelopmentPortDetector.category(for: port) ?? port.process)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(isRunning ? "· \(processLabel) \(pidLabel)" : "· 未运行")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if hasError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("启动命令报错，点击查看日志")
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("查看运行日志")
            .accessibilityLabel("查看端口运行日志")

            if isTransitioning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
                    .help("正在处理")
                    .accessibilityLabel("正在处理")
            } else if isRunning || rule?.command.isEmpty == false {
                Button(action: onToggle) {
                    Image(systemName: isRunning ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isRunning ? Color.secondary : Color.green)
                .help(isRunning ? "暂停端口" : "启动端口")
                .accessibilityLabel(isRunning ? "暂停端口" : "启动端口")
            }

            Button(action: onEdit) {
                Image(systemName: rule == nil && autoDiscovered ? "pencil" : "ellipsis")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(rule == nil && autoDiscovered ? "命名端口" : "编辑端口")
            .accessibilityLabel(rule == nil && autoDiscovered ? "命名端口" : "编辑端口")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            if isRunning && !isTransitioning {
                Button("终止占用此端口的进程", role: .destructive, action: onTerminate)
            }
        }
    }
}

struct PortDropDelegate: DropDelegate {
    let targetKey: String
    @Binding var draggedKey: String?
    let preferences: PortPreferences

    func dropEntered(info: DropInfo) {
        guard let draggedKey, draggedKey != targetKey else { return }
        preferences.move(draggedKey, before: targetKey)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedKey = nil
        return true
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
    let hasError: Bool
    let isTransitioning: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let portLabel = rule.port.map { String($0) } ?? "自动"
        HStack(spacing: 8) {
            Image(systemName: isRunning ? "checkmark.circle.fill" : "terminal.fill")
                .foregroundStyle(isRunning ? .green : .secondary)
                .font(.caption)
            Text(verbatim: rule.name + ":" + portLabel)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(rule.command.isEmpty ? "仅监控" : rule.command)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if isRunning { Text("运行中").font(.caption2).foregroundStyle(.green) }
            if hasError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("启动命令报错")
            }
            Spacer()
            if isTransitioning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
                    .help("正在处理")
                    .accessibilityLabel("正在处理")
            } else if !rule.command.isEmpty {
                Button(action: onToggle) {
                    Image(systemName: isRunning ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isRunning ? Color.secondary : Color.green)
                .help(isRunning ? "暂停端口" : "启动端口")
                .accessibilityLabel(isRunning ? "暂停端口" : "启动端口")
            }
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(isTransitioning)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CommandEditorView: View {
    private let ruleID: UUID
    @State private var name = ""
    @State private var port = ""
    @State private var command = ""
    @State private var workingDirectory = ""
    let onSave: (CommandRule) -> Void
    let onCancel: () -> Void

    init(initialRule: CommandRule? = nil, onSave: @escaping (CommandRule) -> Void, onCancel: @escaping () -> Void) {
        ruleID = initialRule?.id ?? UUID()
        _name = State(initialValue: initialRule?.name ?? "")
        _port = State(initialValue: initialRule?.port.map(String.init) ?? "")
        _command = State(initialValue: initialRule?.command ?? "")
        _workingDirectory = State(initialValue: initialRule?.workingDirectory ?? "")
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加/编辑端口")
                .font(.title3.weight(.semibold))
            TextField("名称，例如：国内 Web", text: $name)
            TextField("端口，例如：3000", text: $port)
                .textFieldStyle(.roundedBorder)
            TextField("命令，例如：pnpm dev", text: $command)
                .textFieldStyle(.roundedBorder)
            TextField("工作目录（可选）", text: $workingDirectory)
                .textFieldStyle(.roundedBorder)
            Text("端口可留空；启动命令后会自动识别新出现的开发端口。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("保存") {
                    let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
                    let portNumber = trimmedPort.isEmpty ? nil : Int(trimmedPort)
                    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          (portNumber != nil || !trimmedCommand.isEmpty) else { return }
                    onSave(CommandRule(id: ruleID, name: name, port: portNumber, command: command, workingDirectory: workingDirectory))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 360)
    }

    private var canSave: Bool {
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let validPort = trimmedPort.isEmpty || (Int(trimmedPort).map { $0 > 0 } ?? false)
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && validPort
            && (!trimmedPort.isEmpty || !trimmedCommand.isEmpty)
    }
}
