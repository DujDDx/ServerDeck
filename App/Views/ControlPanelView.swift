import SwiftUI
import AppKit

struct ControlPanelView: View {
    @EnvironmentObject private var model: AppModel
    @State private var discoveredHosts: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                menuBarSection
                serversSection
                generalSection
            }
            .padding(22)
        }
        .frame(width: 720, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            discoveredHosts = model.discoverSSHHosts()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("ServerDeck")
                    .font(.system(size: 19, weight: .semibold))
                Text("远程服务器 GPU / CPU / 内存实时监控")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(model.onlineSummary.hasPrefix("0/") ? Color.red : Color.green)
                    .frame(width: 6, height: 6)
                Text(model.onlineSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 菜单栏

    private var menuBarSection: some View {
        section("菜单栏", "状态栏上显示什么、多久刷新一次") {
            Picker("", selection: $model.config.menuBarStyle) {
                ForEach(MenuBarStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 12) {
                Text(model.config.menuBarStyle.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                MenuBarContent()
                    .environmentObject(model)
                    .environment(\.colorScheme, .dark)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.78)))
                    .foregroundStyle(.white)
            }

            Divider()

            HStack(spacing: 16) {
                Picker("菜单栏主服务器", selection: $model.config.primaryID) {
                    Text("自动（第一台）").tag(Optional<UUID>.none)
                    ForEach(model.config.servers) { server in
                        Text(server.name).tag(Optional(server.id))
                    }
                }
                .frame(maxWidth: 280)

                Picker("并排主机数", selection: Binding(
                    get: { model.config.maxMenuBarHosts ?? 3 },
                    set: { model.config.maxMenuBarHosts = $0 }
                )) {
                    Text("1 台").tag(1)
                    Text("2 台").tag(2)
                    Text("3 台").tag(3)
                }
                .frame(maxWidth: 150)

                Spacer()

                Toggle("显示 GPU 进程", isOn: $model.config.showProcesses)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            HStack(spacing: 12) {
                Text("刷新间隔")
                Slider(value: $model.config.pollInterval, in: 2...15, step: 1)
                    .frame(width: 220)
                Text("\(Int(model.config.pollInterval)) 秒")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)
            }
        }
    }

    // MARK: 服务器

    private var serversSection: some View {
        section("服务器", "通过 SSH 采集，需要配置好免密登录（SSH key）") {
            if model.config.servers.isEmpty {
                Text("还没有服务器，点击下方按钮添加。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(model.config.servers.enumerated()), id: \.element.id) { index, _ in
                ServerEditorRow(server: $model.config.servers[index])
                if index != model.config.servers.count - 1 {
                    Divider().opacity(0.5)
                }
            }

            HStack {
                Menu {
                    if !discoveredHosts.isEmpty {
                        Section("来自 ~/.ssh/config") {
                            ForEach(discoveredHosts, id: \.self) { host in
                                Button(host) {
                                    model.addServer(name: host, host: host)
                                }
                            }
                        }
                    }
                    Button("手动添加") {
                        model.addServer()
                    }
                } label: {
                    Label("添加服务器", systemImage: "plus")
                }
                .fixedSize()

                Spacer()

                Text("支持别名、user@host、跳板机（ProxyCommand）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: 通用

    private var generalSection: some View {
        section("通用", nil) {
            Toggle("登录时自动启动", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)

            if let error = model.loginItemError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Text("ServerDeck \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("退出 ServerDeck") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        _ subtitle: String?,
                                        @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            SectionHeader(title: title, subtitle: subtitle)
        }
    }
}

// MARK: - 服务器编辑行

struct ServerEditorRow: View {
    @EnvironmentObject private var model: AppModel
    @Binding var server: ServerConfig

    @State private var testing = false
    @State private var testMessage: String?
    @State private var testOK = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("", isOn: $server.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)

                TextField("名称", text: $server.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)

                TextField("SSH 主机（别名或 user@host）", text: $server.host)
                    .textFieldStyle(.roundedBorder)

                Button(testing ? "测试中…" : "测试") {
                    runTest()
                }
                .disabled(testing || server.host.trimmingCharacters(in: .whitespaces).isEmpty)

                Button(role: .destructive) {
                    model.removeServer(id: server.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除这台服务器")
            }

            if let testMessage {
                Text(testMessage)
                    .font(.caption2)
                    .foregroundStyle(testOK ? .green : .red)
                    .lineLimit(2)
            }
        }
    }

    private func runTest() {
        testing = true
        testMessage = nil
        let target = server
        Task {
            let result = await model.testServer(target)
            testOK = result.ok
            testMessage = result.message
            testing = false
        }
    }
}
