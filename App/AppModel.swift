import Foundation
import Combine
import ServiceManagement

// MARK: - 配置模型

enum MenuBarStyle: String, Codable, CaseIterable, Identifiable {
    case iconOnly
    case compact
    case memory
    case overview
    case gpuBars
    case gpuRings
    case allMetrics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iconOnly:   return "图标"
        case .compact:    return "GPU/CPU"
        case .memory:     return "显存/CPU"
        case .overview:   return "多机"
        case .gpuBars:    return "GPU 条"
        case .gpuRings:   return "GPU 环"
        case .allMetrics: return "全指标"
        }
    }

    var detail: String {
        switch self {
        case .iconOnly:   return "菜单栏只显示一个服务器图标"
        case .compact:    return "显示主服务器的 GPU 与 CPU 占用"
        case .memory:     return "显示显存用量与 CPU 占用"
        case .overview:   return "显示在线台数与最高 GPU 占用"
        case .gpuBars:    return "最多 3 台主机并排；每张 GPU 上下两条：占用 / 显存"
        case .gpuRings:   return "最多 3 台主机并排；每张 GPU 双环：外环占用、内环显存"
        case .allMetrics: return "GPU 双条 + 每台主机的 CPU / 内存百分比"
        }
    }

    /// 这三种样式按主机并排渲染 GPU 指标。
    var isGPUIndicator: Bool {
        self == .gpuBars || self == .gpuRings || self == .allMetrics
    }
}

struct ServerConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var enabled = true

    init(id: UUID = UUID(), name: String, host: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.host = host
        self.enabled = enabled
    }
}

struct AppConfig: Codable {
    var servers: [ServerConfig] = []
    var primaryID: UUID?
    var menuBarStyle: MenuBarStyle = .compact
    var pollInterval: Double = 3
    var showProcesses: Bool = true
    /// 菜单栏最多并排显示几台主机（1–3），默认 3。
    var maxMenuBarHosts: Int? = nil
}

struct HistorySample: Identifiable {
    let id = UUID()
    let date: Date
    let gpu: Double
    let cpu: Double
    let mem: Double
}

// MARK: - 应用状态

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var config: AppConfig {
        didSet {
            persistConfig()
            writeSharedFile()
        }
    }

    @Published private(set) var snapshots: [UUID: HostSnapshot] = [:]
    @Published private(set) var histories: [UUID: [HistorySample]] = [:]
    @Published private(set) var coreHistories: [UUID: [[Double]]] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published var loginItemError: String?

    private var pollTask: Task<Void, Never>?
    private static let configKey = "ServerDeck.config.v1"

    /// 配置放在 App Group 里：主程序启用沙盒后，UserDefaults 会落到容器中，
    /// 用共享文件可以保持配置稳定，也方便排查。
    private static var configFileURL: URL {
        SnapshotStore.directory.appendingPathComponent("config.json")
    }

    private init() {
        SnapshotStore.ensureDirectory()
        config = Self.loadConfig()
        persistConfig()
        startPolling()
    }

    deinit { pollTask?.cancel() }

    // MARK: 轮询

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                let interval = self?.config.pollInterval ?? 3
                try? await Task.sleep(nanoseconds: UInt64(max(1, interval) * 1_000_000_000))
            }
        }
    }

    func refreshNow() {
        Task { await refreshAll() }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        let servers = config.servers.filter { $0.enabled && !$0.host.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !servers.isEmpty else {
            snapshots = [:]
            writeSharedFile()
            return
        }

        isRefreshing = true
        await withTaskGroup(of: HostSnapshot.self) { group in
            for server in servers {
                group.addTask { await Self.fetch(server) }
            }
            // 每台服务器返回就立即更新，慢的机器不会拖住其它机器。
            for await snapshot in group {
                apply(snapshot)
            }
        }

        isRefreshing = false
        lastRefresh = Date()
        writeSharedFile()
    }

    nonisolated static func fetch(_ server: ServerConfig) async -> HostSnapshot {
        let result = await SSHClient.run(host: server.host,
                                         script: RemoteMetrics.script,
                                         controlDirectory: SnapshotStore.sshDirectory)
        guard result.isSuccess else {
            return .offline(id: server.id, name: server.name, host: server.host, error: result.errorText)
        }
        var snapshot = MetricsParser.parse(output: result.stdout,
                                           id: server.id,
                                           name: server.name,
                                           host: server.host)
        if !snapshot.online {
            snapshot.error = "远端脚本未完整返回"
        }
        return snapshot
    }

    private func apply(_ snapshot: HostSnapshot) {
        snapshots[snapshot.id] = snapshot
        guard snapshot.online else { return }
        var list = histories[snapshot.id] ?? []
        list.append(HistorySample(date: snapshot.timestamp,
                                  gpu: snapshot.gpuUtilizationMaxFraction,
                                  cpu: snapshot.cpuUsage,
                                  mem: snapshot.memFraction))
        if list.count > 150 { list.removeFirst(list.count - 150) }
        histories[snapshot.id] = list

        if let cores = snapshot.coreUsages, !cores.isEmpty {
            var coreList = coreHistories[snapshot.id] ?? []
            coreList.append(cores)
            if coreList.count > 8 { coreList.removeFirst(coreList.count - 8) }
            coreHistories[snapshot.id] = coreList
        }
    }

    // MARK: 共享文件 / Widget

    private func writeSharedFile() {
        let ordered = config.servers.compactMap { snapshots[$0.id] }
        SnapshotStore.save(SnapshotFile(updatedAt: Date(), primaryID: config.primaryID, hosts: ordered))
    }

    // MARK: 菜单栏展示

    var primarySnapshot: HostSnapshot? {
        if let id = config.primaryID, let snapshot = snapshots[id] { return snapshot }
        return config.servers.compactMap { snapshots[$0.id] }.first
    }

    /// 菜单栏最多并排展示的主机数，主服务器排在最前。
    var menuBarHosts: [HostSnapshot] {
        var servers = config.servers.filter(\.enabled)
        if let primaryID = config.primaryID,
           let index = servers.firstIndex(where: { $0.id == primaryID }) {
            let primary = servers.remove(at: index)
            servers.insert(primary, at: 0)
        }
        let limit = min(max(config.maxMenuBarHosts ?? 3, 1), 3)
        return servers.prefix(limit).compactMap { snapshots[$0.id] }
    }

    var menuBarText: String? {
        switch config.menuBarStyle {
        case .iconOnly, .gpuBars, .gpuRings, .allMetrics:
            return nil

        case .compact:
            guard let snapshot = primarySnapshot else { return "…" }
            guard snapshot.online else { return "离线" }
            return "\(Int(snapshot.gpuUtilizationMax.rounded()))% · \(Int((snapshot.cpuUsage * 100).rounded()))%"

        case .memory:
            guard let snapshot = primarySnapshot else { return "…" }
            guard snapshot.online else { return "离线" }
            let vram = snapshot.gpus.isEmpty ? "无 GPU" : "\(Fmt.gb(snapshot.vramUsedGB))/\(Fmt.gb(snapshot.vramTotalGB))G"
            return "\(vram) · \(Int((snapshot.cpuUsage * 100).rounded()))%"

        case .overview:
            let enabled = config.servers.filter(\.enabled)
            guard !enabled.isEmpty else { return "未配置" }
            let snaps = enabled.compactMap { snapshots[$0.id] }
            guard !snaps.isEmpty else { return "…" }
            let online = snaps.filter(\.online).count
            let gpu = snaps.map(\.gpuUtilizationMax).max() ?? 0
            return "\(online)/\(enabled.count) · \(Int(gpu.rounded()))%"
        }
    }

    /// 状态栏图标的悬停提示。
    var menuBarTooltip: String {
        let hosts = menuBarHosts
        guard !hosts.isEmpty else { return "ServerDeck" }
        return hosts.map { host -> String in
            let gpu = host.gpus.isEmpty
                ? ""
                : " GPU " + host.gpus.map { "\(Int($0.utilization.rounded()))%" }.joined(separator: "/")
            return "\(host.name): CPU \(Int((host.cpuUsage * 100).rounded()))% · 内存 \(Int((host.memFraction * 100).rounded()))%\(gpu)"
        }
        .joined(separator: "\n")
    }

    var onlineSummary: String {
        let enabled = config.servers.filter(\.enabled)
        guard !enabled.isEmpty else { return "尚未配置服务器" }
        let online = enabled.filter { snapshots[$0.id]?.online == true }.count
        return "\(online)/\(enabled.count) 台在线"
    }

    // MARK: 服务器管理

    func addServer(name: String = "新服务器", host: String = "") {
        let server = ServerConfig(name: name, host: host)
        config.servers.append(server)
        if config.primaryID == nil { config.primaryID = server.id }
    }

    func removeServer(id: UUID) {
        config.servers.removeAll { $0.id == id }
        snapshots[id] = nil
        histories[id] = nil
        coreHistories[id] = nil
        if config.primaryID == id { config.primaryID = config.servers.first?.id }
    }

    func testServer(_ server: ServerConfig) async -> (ok: Bool, message: String) {
        guard !server.host.trimmingCharacters(in: .whitespaces).isEmpty else {
            return (false, "请先填写 SSH 主机")
        }
        let result = await SSHClient.test(host: server.host, controlDirectory: SnapshotStore.sshDirectory)
        guard result.isSuccess else { return (false, "连接失败：\(result.errorText)") }

        var hostname = server.host
        var cores = "?"
        var gpus = "0"
        for line in result.stdout.split(separator: "\n") {
            if line.hasPrefix("HOSTNAME=") { hostname = String(line.dropFirst(9)) }
            if line.hasPrefix("CORES=") { cores = String(line.dropFirst(6)) }
            if line.hasPrefix("GPU_COUNT=") { gpus = String(line.dropFirst(10)) }
        }
        return (true, "连接成功 · \(hostname) · \(cores) 核 · \(gpus) 张 GPU")
    }

    /// 从 ~/.ssh/config 读取可用主机别名，方便一键添加。
    func discoverSSHHosts() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var hosts: [String] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            guard lower.hasPrefix("host ") else { continue }
            let names = trimmed.dropFirst(5).split(whereSeparator: { $0 == " " || $0 == "\t" })
            for name in names.map(String.init) where !name.contains("*") && !name.contains("?") && !name.contains("!") {
                if !hosts.contains(name) { hosts.append(name) }
            }
        }
        return hosts
    }

    // MARK: 开机启动

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        objectWillChange.send()
    }

    // MARK: 持久化

    private func persistConfig() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: Self.configFileURL, options: .atomic)
        UserDefaults.standard.set(data, forKey: Self.configKey)
    }

    private static func loadConfig() -> AppConfig {
        if let data = try? Data(contentsOf: configFileURL),
           let saved = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return saved
        }
        if let data = UserDefaults.standard.data(forKey: configKey),
           let saved = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return saved
        }
        return AppConfig()
    }
}
