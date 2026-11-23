import Foundation

// MARK: - 单块 GPU

struct GPUMetric: Codable, Hashable, Identifiable {
    var id: Int { index }
    var index: Int
    var name: String
    var utilization: Double          // 0...100
    var memoryUsedMB: Double
    var memoryTotalMB: Double
    var temperature: Double?         // ℃
    var powerDraw: Double?           // W
    var powerLimit: Double?          // W

    var memoryFraction: Double {
        memoryTotalMB > 0 ? min(1, max(0, memoryUsedMB / memoryTotalMB)) : 0
    }
    var utilizationFraction: Double { min(1, max(0, utilization / 100)) }
    var memoryUsedGB: Double { memoryUsedMB / 1024 }
    var memoryTotalGB: Double { memoryTotalMB / 1024 }
}

struct GPUProcess: Codable, Hashable, Identifiable {
    var id: String { "\(pid)-\(name)" }
    var pid: Int
    var memoryMB: Double
    var name: String

    var memoryGB: Double { memoryMB / 1024 }
    var shortName: String { (name as NSString).lastPathComponent }
}

// MARK: - 一台服务器的快照

struct HostSnapshot: Codable, Hashable, Identifiable {
    var id: UUID                    // 对应 ServerConfig.id
    var name: String
    var host: String
    var timestamp: Date
    var online: Bool
    var error: String?

    var hostname: String?
    var coreCount: Int
    var gpus: [GPUMetric]
    var gpuProcesses: [GPUProcess]

    var cpuUsage: Double            // 0...1
    var memUsedBytes: Double
    var memTotalBytes: Double
    var load1: Double
    var load5: Double
    var load15: Double
    var uptime: Double              // 秒

    // 更细的指标；旧版本快照可能没有这些字段，因此保持可选。
    var cpuUser: Double? = nil
    var cpuSystem: Double? = nil
    var cpuIO: Double? = nil
    var cpuSteal: Double? = nil
    var coreUsages: [Double]? = nil
    var memFreeBytes: Double? = nil
    var memCachedBytes: Double? = nil

    var cpuUserValue: Double { cpuUser ?? 0 }
    var cpuSystemValue: Double { cpuSystem ?? 0 }
    var cpuIOValue: Double { cpuIO ?? 0 }
    var cpuStealValue: Double { cpuSteal ?? 0 }
    var coreUsageList: [Double] { coreUsages ?? [] }
    var memFree: Double { memFreeBytes ?? 0 }
    var memCached: Double { memCachedBytes ?? 0 }
    var idleFraction: Double { max(0, 1 - cpuUsage) }

    var memFraction: Double {
        memTotalBytes > 0 ? min(1, max(0, memUsedBytes / memTotalBytes)) : 0
    }
    var memUsedGB: Double { memUsedBytes / 1_073_741_824 }
    var memTotalGB: Double { memTotalBytes / 1_073_741_824 }

    var gpuUtilizationMax: Double { gpus.map(\.utilization).max() ?? 0 }
    var gpuUtilizationMaxFraction: Double { min(1, gpuUtilizationMax / 100) }
    var vramUsedGB: Double { gpus.reduce(0) { $0 + $1.memoryUsedGB } }
    var vramTotalGB: Double { gpus.reduce(0) { $0 + $1.memoryTotalGB } }
    var vramFraction: Double { vramTotalGB > 0 ? min(1, vramUsedGB / vramTotalGB) : 0 }
    var gpuCount: Int { gpus.count }

    /// 菜单栏用的短名称，最多 6 个字符。
    var shortLabel: String {
        let base = (name.isEmpty ? host : name).trimmingCharacters(in: .whitespaces)
        if base.isEmpty { return "主机" }
        if base.count <= 6 { return base }
        return String(base.prefix(6))
    }

    static func offline(id: UUID, name: String, host: String, error: String) -> HostSnapshot {
        HostSnapshot(id: id, name: name, host: host, timestamp: Date(), online: false, error: error,
                     hostname: nil, coreCount: 0, gpus: [], gpuProcesses: [],
                     cpuUsage: 0, memUsedBytes: 0, memTotalBytes: 0,
                     load1: 0, load5: 0, load15: 0, uptime: 0)
    }
}

// MARK: - 供 Widget 读取的共享文件

struct SnapshotFile: Codable {
    var version: Int = 1
    var updatedAt: Date
    var primaryID: UUID?
    var hosts: [HostSnapshot]

    static let empty = SnapshotFile(updatedAt: .distantPast, primaryID: nil, hosts: [])

    var primary: HostSnapshot? {
        if let primaryID, let match = hosts.first(where: { $0.id == primaryID }) { return match }
        return hosts.first
    }
}

// MARK: - 展示格式化

enum Fmt {
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }

    static func gb(_ value: Double) -> String {
        if value >= 100 { return String(format: "%.0f", value) }
        if value >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }

    static func memory(_ bytes: Double) -> String {
        let gb = bytes / 1_073_741_824
        if gb >= 1024 { return String(format: "%.1f TB", gb / 1024) }
        return String(format: "%.1f GB", gb)
    }

    static func watts(_ value: Double?) -> String? {
        guard let value, value.isFinite else { return nil }
        return String(format: "%.0f W", value)
    }

    static func celsius(_ value: Double?) -> String? {
        guard let value, value.isFinite else { return nil }
        return String(format: "%.0f°C", value)
    }

    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 3 { return "刚刚" }
        if seconds < 60 { return "\(Int(seconds)) 秒前" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        return "\(Int(seconds / 86400)) 天前"
    }

    static func uptime(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        let days = Int(seconds) / 86400
        let hours = (Int(seconds) % 86400) / 3600
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        let minutes = (Int(seconds) % 3600) / 60
        return "\(hours) 小时 \(minutes) 分"
    }

    /// 仪表盘用的紧凑运行时长："14 小时" / "3 天 2 小时"。
    static func uptimeShort(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        let days = Int(seconds) / 86400
        let hours = (Int(seconds) % 86400) / 3600
        if days > 0 { return "\(days) 天 \(hours) 时" }
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "\(hours) 时 \(minutes) 分" : "\(minutes) 分"
    }

    static func load(_ value: Double) -> String { String(format: "%.2f", value) }

    /// "5.0 / 5.1 / 5.0"
    static func loadTriple(_ a: Double, _ b: Double, _ c: Double) -> String {
        String(format: "%.1f / %.1f / %.1f", a, b, c)
    }
}
