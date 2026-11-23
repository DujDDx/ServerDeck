# ServerDeck

macOS 菜单栏的远程 Linux 服务器监控。

## 下载

预编译版本：[Releases](https://github.com/DujDDx/ServerDeck/releases/latest)（macOS 14+，arm64 + x86_64 通用二进制）。

通过 SSH 定时执行一段**只读**脚本，采集：

- **GPU**：利用率、显存占用、温度、功耗（`nvidia-smi`，支持多卡）
- **CPU**：总体使用率、系统/用户/IO等待/STEAL 细分、每核占用
- **内存**：已用 / 可用 / 页面缓存
- 负载、运行时长、占用显存的进程

## 功能

- **菜单栏**：7 种显示样式，最多并排 3 台主机
  - 图标：只显示一个服务器图标
  - `GPU% · CPU%`
  - `显存用量 · CPU%`
  - 多机总览（在线台数 · 最高 GPU 占用）
  - **GPU 条**：每台主机并排；每张 GPU 上下两条进度条 —— 上=占用，下=显存
  - **GPU 环**：每张 GPU 双环 —— 外环占用，内环显存
  - **全指标**：GPU 双条 + 每台主机的 CPU / 内存百分比
  - 没有 GPU 的主机自动退化为 CPU / 内存双指标
- **下拉面板**：仪表盘风格
  - CPU 大数字 + 系统 / 用户 / IO等待 / STEAL 细分
  - 每核占用热力图（最近 8 次采样）
  - 核数、空闲、运行时间、负载
  - 可用 / 已用 / 页面缓存 + 环形内存表
  - 每张 GPU 的分段双进度条（占用 / 显存）、温度、功耗
  - GPU 进程列表
- **多服务器**：服务器增删、连通性测试、从 `~/.ssh/config` 导入别名
- **控制面板**：菜单栏样式、主服务器、并排主机数（1–3）、刷新间隔（2–15 秒）、开机自启
- **隐私**：数据只在本机与你的服务器之间传输，无遥测、无第三方服务

## 系统要求

- macOS 14 或更高
- 服务器：Linux，可免密 SSH 登录（密钥）；GPU 数据需要 `nvidia-smi`，没有也能显示 CPU/内存
- 构建：Xcode 命令行工具

## 构建与安装

```bash
./build.sh install
```

其它命令：

```bash
./build.sh build    # 只构建到 dist/ServerDeck.app
./build.sh release  # 通用架构（arm64+x86_64）+ ad-hoc 签名的发布包
./build.sh run      # 构建并运行（不安装）
./build.sh clean    # 清理构建产物
```

安装脚本会编译主程序、生成图标、签名并安装到 `/Applications/ServerDeck.app`。默认自动从钥匙串选择 `Apple Development` 证书，没有则使用 ad-hoc 签名（本地运行没有问题）。

### 发布

```bash
./build.sh release
```

产物为 `dist/ServerDeck-<版本>-macos.zip`，包含 arm64 + x86_64 通用二进制，使用 ad-hoc 签名。首次打开如被 Gatekeeper 拦截，右键应用 → 打开即可。

## 使用

### 状态栏

启动后菜单栏出现一个服务器图标与实时数据。

- **左键**：打开下拉面板
- **悬停**：查看每台主机的 CPU / 内存 / GPU 摘要
- **面板右上角齿轮**：打开控制面板
- 面板底部：立即刷新 / 退出

`GPU 条` / `GPU 环` / `全指标` 三种样式会把**最多 3 台启用中的主机**并排显示，主服务器排在最前。如果状态栏空间不够、图标被折叠，可以在控制面板把「并排主机数」调小。

### 添加服务器

首次启动时还没有服务器。打开控制面板：

1. 打开控制面板（菜单栏 → 齿轮，或面板底部「控制面板」）
2. 在「服务器」一节点「添加服务器」
3. 可以从 `~/.ssh/config` 里直接选择别名，也可以手动填写 `user@host`
4. 点「测试」确认连通，成功会显示主机名、核数、GPU 数量

应用使用系统 `ssh`（`BatchMode=yes`），请提前配置好密钥登录：

```bash
ssh-copy-id user@your-server
```

### 开机自启

控制面板 → 通用 → 登录时自动启动。

## 工作原理

```
┌─────────────┐   ssh (ControlMaster 复用)   ┌────────────────────┐
│ ServerDeck  │ ───────────────────────────► │ 远程服务器          │
│  (菜单栏)    │      只读 shell 脚本          │ /proc + nvidia-smi │
└──────┬──────┘                              └────────────────────┘
       │ 写入 JSON 快照
       ▼
~/Library/Application Support/ServerDeck/snapshot.json
```

- 每次采集只建立一次 SSH 会话（多路复用），一次取回全部指标
- CPU 使用率、每核占用与系统/用户/IO等待/STEAL 细分都在服务器端用 0.4 秒窗口的 `/proc/stat` 差值计算，避免本地维护状态
- 菜单栏图标由 SwiftUI 视图经 `ImageRenderer` 渲染为模板图，状态栏宽度随内容自适应
- 所有远端命令均为只读

## 目录结构

```
Serverdeck/
├── App/
│   ├── ServerDeckApp.swift        # AppKit 入口、状态栏、弹出面板、控制面板窗口
│   ├── AppModel.swift             # 配置、轮询、状态
│   ├── SSHClient.swift            # 调用系统 ssh，超时与并发
│   └── Views/
│       ├── MenuBarIndicators.swift # 菜单栏多主机 GPU 图形
│       ├── PopoverView.swift       # 仪表盘下拉面板
│       ├── ControlPanelView.swift  # 控制面板
│       └── Components.swift        # 分段条、热力图、环形表等
├── Shared/
│   ├── Models.swift               # 数据模型与格式化
│   ├── MetricsParser.swift        # 远端脚本与输出解析
│   └── SnapshotStore.swift        # 快照读写
├── Resources/AppInfo.plist
├── tools/make_icon.swift
└── build.sh
```


## 常见问题

**连接被拒绝 / Permission denied**

先在终端验证：`ssh -o BatchMode=yes <host> hostname`。必须是密钥免密登录，应用不会弹密码框。

**没有 GPU 数据**

服务器没有 `nvidia-smi`（例如 HPC 登录节点），或驱动未装。CPU/内存仍会正常显示。

**状态栏图标被折叠 / 看不到**

菜单栏空间不足时系统会隐藏状态项。可以在控制面板把「并排主机数」调小，或移除一些其它菜单栏图标。

**服务器不可达时**

卡片会显示红色状态与错误信息，不影响其它服务器；恢复后自动继续。

## 卸载

```bash
rm -rf /Applications/ServerDeck.app
rm -rf "$HOME/Library/Application Support/ServerDeck"
defaults delete com.dujddx.serverdeck
```
