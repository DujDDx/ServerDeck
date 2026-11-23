import SwiftUI

/// 菜单栏里实际渲染的内容（控制面板的预览也复用它）。
struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "server.rack")

            switch model.config.menuBarStyle {
            case .iconOnly:
                EmptyView()

            case .compact, .memory, .overview:
                if let text = model.menuBarText {
                    Text(text).monospacedDigit()
                }

            case .gpuBars, .gpuRings, .allMetrics:
                GPUHostStrip(hosts: model.menuBarHosts, style: model.config.menuBarStyle)
            }
        }
    }
}

// MARK: - 多主机并排

struct GPUHostStrip: View {
    let hosts: [HostSnapshot]
    let style: MenuBarStyle

    var body: some View {
        if hosts.isEmpty {
            Text("…")
        } else {
            HStack(spacing: 3) {
                ForEach(Array(hosts.enumerated()), id: \.element.id) { index, host in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.22))
                            .frame(width: 1, height: 11)
                    }

                    HStack(spacing: 3) {
                        if hosts.count > 1 {
                            Text(host.shortLabel)
                                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }

                        if host.online {
                            ForEach(host.gpus.prefix(8)) { gpu in
                                GPUStatusGlyph(util: gpu.utilizationFraction,
                                               vram: gpu.memoryFraction,
                                               ring: style == .gpuRings)
                            }
                            if host.gpus.isEmpty {
                                // 没有 GPU 的主机退化为 CPU / 内存双指标
                                GPUStatusGlyph(util: host.cpuUsage,
                                               vram: host.memFraction,
                                               ring: style == .gpuRings)
                            }
                            if style == .allMetrics {
                                Text("C\(Int((host.cpuUsage * 100).rounded())) M\(Int((host.memFraction * 100).rounded()))")
                                    .font(.system(size: 8, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                        } else {
                            Text("离线")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 单个 GPU 的双指标图形

struct GPUStatusGlyph: View {
    var util: Double
    var vram: Double
    var ring: Bool = false

    var body: some View {
        if ring {
            ZStack {
                // 外环：GPU 占用
                Circle()
                    .stroke(Color.primary.opacity(0.18), lineWidth: 1.6)
                Circle()
                    .trim(from: 0, to: clamp(util))
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                // 内环：显存占用
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1.3)
                    .padding(3.8)
                Circle()
                    .trim(from: 0, to: clamp(vram))
                    .stroke(Color.primary.opacity(0.55), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(3.8)
            }
            .frame(width: 16, height: 16)
        } else {
            VStack(spacing: 2) {
                bar(util, opacity: 1.0)
                bar(vram, opacity: 0.45)
            }
            .frame(width: 20, height: 9)
        }
    }

    private func bar(_ fraction: Double, opacity: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.14))
            GeometryReader { geo in
                Capsule()
                    .fill(Color.primary.opacity(opacity))
                    .frame(width: max(1, geo.size.width * clamp(fraction)))
            }
        }
        .frame(height: 3.5)
    }
    private func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
