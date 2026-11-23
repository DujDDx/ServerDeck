import SwiftUI
import AppKit

struct PopoverView: View {
    @EnvironmentObject private var model: AppModel
    var onOpenPanel: () -> Void = {}
    var onHeightChange: ((CGFloat) -> Void)? = nil
    @State private var contentHeight: CGFloat = 420

    private var activeServers: [ServerConfig] {
        model.config.servers.filter(\.enabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 430)
        .background(.regularMaterial)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PopoverRootHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(PopoverRootHeightKey.self) { height in
            onHeightChange?(min(max(height, 220), 820))
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("ServerDeck")
                    .font(.system(size: 14, weight: .semibold))
                Text(model.onlineSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                model.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("立即刷新")

            Button {
                openPanel()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("控制面板")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: 内容

    private var content: some View {
        ScrollView {
            VStack(spacing: 12) {
                if activeServers.isEmpty {
                    emptyState
                } else {
                    ForEach(activeServers) { server in
                        ServerCard(server: server,
                                   snapshot: model.snapshots[server.id],
                                   coreHistory: model.coreHistories[server.id] ?? [],
                                   showProcesses: model.config.showProcesses,
                                   onRetry: { model.refreshNow() })
                    }
                }
            }
            .padding(12)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: PopoverHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .frame(height: min(max(contentHeight, 160), 700))
        .onPreferenceChange(PopoverHeightKey.self) { height in
            let clamped = min(max(height, 160), 700)
            if abs(clamped - contentHeight) > 0.5 {
                contentHeight = clamped
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("还没有配置服务器")
                .font(.callout)
            Button("打开控制面板") { openPanel() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                openPanel()
            } label: {
                Label("控制面板", systemImage: "slider.horizontal.3")
            }
            Button {
                model.refreshNow()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func openPanel() {
        onOpenPanel()
    }
}

private struct PopoverHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PopoverRootHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - 服务器卡片

struct ServerCard: View {
    let server: ServerConfig
    let snapshot: HostSnapshot?
    let coreHistory: [[Double]]
    let showProcesses: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                StatusDot(online: snapshot?.online == true, pending: snapshot == nil)
                Text(server.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(server.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let snapshot {
                    Text(Fmt.age(snapshot.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let snapshot {
                if snapshot.online {
                    onlineContent(snapshot)
                } else {
                    offlineContent(snapshot)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在连接…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.sdCard))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.sdCardBorder))
    }

    @ViewBuilder
    private func onlineContent(_ snapshot: HostSnapshot) -> some View {
        let heatHistory = coreHistory.isEmpty ? [snapshot.coreUsageList] : coreHistory

        CPUBlock(snapshot: snapshot, coreHistory: heatHistory)

        Divider().opacity(0.35)

        MemoryBlock(snapshot: snapshot)

        if !snapshot.gpus.isEmpty {
            Divider().opacity(0.35)
            GPUBlock(gpus: snapshot.gpus)
        } else {
            Text("未检测到 NVIDIA GPU")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        if showProcesses && !snapshot.gpuProcesses.isEmpty {
            Divider().opacity(0.35)
            ProcessBlock(processes: snapshot.gpuProcesses)
        }
    }

    @ViewBuilder
    private func offlineContent(_ snapshot: HostSnapshot) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("无法连接")
                    .font(.caption)
                    .fontWeight(.medium)
                Text(snapshot.error ?? "未知错误")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer()
            Button("重试", action: onRetry)
                .controlSize(.mini)
        }
    }
}

// MARK: - CPU 区块

struct CPUBlock: View {
    let snapshot: HostSnapshot
    let coreHistory: [[Double]]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int((snapshot.cpuUsage * 100).rounded()))")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                HStack(spacing: 9) {
                    legend("系统", snapshot.cpuSystemValue, .orange)
                    legend("用户", snapshot.cpuUserValue, .green)
                    legend("IO等待", snapshot.cpuIOValue, .purple)
                    legend("STEAL", snapshot.cpuStealValue, .yellow)
                }
            }

            CoreHeatmap(history: coreHistory,
                        columns: max(snapshot.coreCount, snapshot.coreUsageList.count))
                .frame(height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            HStack(spacing: 0) {
                stat("核数", "\(snapshot.coreCount)")
                stat("空闲", Fmt.percent(snapshot.idleFraction))
                stat("运行时间", Fmt.uptimeShort(snapshot.uptime))
                stat("负载", Fmt.loadTriple(snapshot.load1, snapshot.load5, snapshot.load15))
            }
        }
    }

    private func legend(_ label: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            Text(Fmt.percent(value))
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 内存区块

struct MemoryBlock: View {
    let snapshot: HostSnapshot

    var body: some View {
        HStack(spacing: 14) {
            stat("可用", Fmt.memory(snapshot.memFree), color: .green)
            stat("已用", Fmt.memory(snapshot.memUsedBytes), color: .sdMEM)
            stat("页面缓存", Fmt.memory(snapshot.memCached), color: .secondary)
            Spacer()
            RingGauge(fraction: snapshot.memFraction, tint: .sdMEM, size: 36)
        }
    }

    private func stat(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}

// MARK: - GPU 区块

struct GPUBlock: View {
    let gpus: [GPUMetric]

    private var modelName: String {
        let names = Set(gpus.map(\.name))
        if names.count == 1, let name = names.first { return name.uppercased() }
        return "GPU"
    }

    private var hasMixedModels: Bool {
        Set(gpus.map(\.name)).count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(modelName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("上 占用 · 下 显存")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }

            ForEach(gpus) { gpu in
                VStack(spacing: 3) {
                    HStack(spacing: 6) {
                        Text("GPU \(gpu.index)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        if hasMixedModels {
                            Text(gpu.name)
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Text("\(Int(gpu.utilization.rounded()))%")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Spacer()
                        Text("\(Fmt.gb(gpu.memoryUsedGB)) / \(Fmt.gb(gpu.memoryTotalGB)) GB")
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if let temperature = Fmt.celsius(gpu.temperature) {
                            Text(temperature)
                                .font(.system(size: 9))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        if let power = Fmt.watts(gpu.powerDraw) {
                            Text(power)
                                .font(.system(size: 9))
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                    }

                    SegmentedBar(fraction: gpu.utilizationFraction,
                                 tint: loadTint(gpu.utilizationFraction),
                                 segments: 40,
                                 height: 6)
                    SegmentedBar(fraction: gpu.memoryFraction,
                                 tint: .sdGPU,
                                 segments: 40,
                                 height: 5)
                }
            }
        }
    }
}

// MARK: - GPU 进程

struct ProcessBlock: View {
    let processes: [GPUProcess]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("GPU 进程")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            ForEach(processes.prefix(3)) { process in
                HStack(spacing: 6) {
                    Text(process.shortName)
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("#\(process.pid)")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(Fmt.gb(process.memoryGB)) GB")
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
