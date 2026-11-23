import SwiftUI

// MARK: - 主题色

extension Color {
    static let sdGPU = Color(red: 0.20, green: 0.80, blue: 0.66)
    static let sdCPU = Color(red: 0.36, green: 0.62, blue: 1.00)
    static let sdMEM = Color(red: 0.72, green: 0.50, blue: 1.00)
    static let sdCard = Color.primary.opacity(0.045)
    static let sdCardBorder = Color.primary.opacity(0.08)
}

func loadTint(_ fraction: Double) -> Color {
    if fraction >= 0.92 { return .red }
    if fraction >= 0.75 { return .orange }
    return .green
}

// MARK: - 状态点

struct StatusDot: View {
    var online: Bool
    var pending: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: 14, height: 14)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .help(online ? "在线" : (pending ? "连接中" : "离线"))
    }

    private var color: Color {
        if online { return .green }
        return pending ? .orange : .red
    }
}

// MARK: - 进度条

struct MetricBar: View {
    var fraction: Double
    var tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

// MARK: - 迷你折线

struct Sparkline: View {
    var values: [Double]
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            if values.count > 1 {
                let points = values.enumerated().map { index, value -> CGPoint in
                    let x = width * CGFloat(index) / CGFloat(values.count - 1)
                    let y = height - height * CGFloat(min(1, max(0, value))) * 0.92 - height * 0.04
                    return CGPoint(x: x, y: y)
                }

                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: height))
                        for point in points { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: width, y: height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))

                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            } else {
                Capsule().fill(Color.primary.opacity(0.08)).frame(height: 1.4)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }
}

// MARK: - 分段进度条（仪表盘风格）

struct SegmentedBar: View {
    var fraction: Double
    var tint: Color
    var segments: Int = 40
    var height: CGFloat = 6

    var body: some View {
        Canvas { context, size in
            let count = max(1, segments)
            let gap: CGFloat = 1.5
            let width = max(1, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            let filled = Int((min(1, max(0, fraction)) * Double(count)).rounded())
            for index in 0..<count {
                let rect = CGRect(x: CGFloat(index) * (width + gap),
                                  y: 0,
                                  width: width,
                                  height: size.height)
                let color = index < filled ? tint : Color.primary.opacity(0.09)
                context.fill(Path(roundedRect: rect, cornerRadius: min(1.5, width / 3)),
                             with: .color(color))
            }
        }
        .frame(height: height)
    }
}

// MARK: - 环形表

struct RingGauge: View {
    var fraction: Double
    var tint: Color
    var size: CGFloat = 36
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(Fmt.percent(fraction))
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 每核占用热力图

struct CoreHeatmap: View {
    var history: [[Double]]     // 每次采样一个数组，按时间从旧到新
    var columns: Int

    var body: some View {
        Canvas { context, size in
            let rows = max(1, history.count)
            let cols = max(1, min(columns, 96))
            let gap: CGFloat = 1.5
            let cellWidth = max(1, (size.width - gap * CGFloat(cols - 1)) / CGFloat(cols))
            let cellHeight = max(1, (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows))

            for row in 0..<rows {
                let sample = row < history.count ? history[row] : []
                for col in 0..<cols {
                    let value = col < sample.count ? sample[col] : 0
                    let rect = CGRect(x: CGFloat(col) * (cellWidth + gap),
                                      y: CGFloat(row) * (cellHeight + gap),
                                      width: cellWidth,
                                      height: cellHeight)
                    context.fill(Path(roundedRect: rect, cornerRadius: min(1.5, cellHeight / 3)),
                                 with: .color(heat(value)))
                }
            }
        }
    }

    private func heat(_ value: Double) -> Color {
        let clamped = min(1, max(0, value))
        if clamped < 0.02 { return Color.primary.opacity(0.07) }
        let hue = 0.33 * (1 - clamped)          // 0.33 绿 → 0 红
        return Color(hue: hue, saturation: 0.72, brightness: 1.0)
            .opacity(0.35 + 0.65 * clamped)
    }
}

// MARK: - 小节标题

struct SectionHeader: View {
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
