import SwiftUI
import AppKit
import Combine

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel.shared
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var panelWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var pendingRender: DispatchWorkItem?

    private static var retainedDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        // NSApplication.delegate 是弱引用，必须自己持有，否则状态栏项会随 delegate 释放而消失。
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SnapshotStore.ensureDirectory()
        installMainMenu()
        setupStatusItem()
        setupPopover()

        Publishers.CombineLatest(model.$config, model.$snapshots)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleStatusRender() }
            .store(in: &cancellables)

        scheduleStatusRender()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlPanel()
        return true
    }

    // MARK: 状态栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.imagePosition = .imageOnly
        item.button?.setAccessibilityLabel("ServerDeck 服务器状态")
        statusItem = item
    }

    private func scheduleStatusRender() {
        pendingRender?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.renderStatusItem() }
        pendingRender = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func renderStatusItem() {
        guard let button = statusItem?.button else { return }
        let content = MenuBarContent()
            .environmentObject(model)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return }
        let image = NSImage(cgImage: cgImage,
                            size: NSSize(width: CGFloat(cgImage.width) / 2,
                                         height: CGFloat(cgImage.height) / 2))
        image.isTemplate = true
        button.image = image
        button.toolTip = model.menuBarTooltip
    }

    // MARK: 下拉面板

    private func setupPopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 430, height: 560)
        let controller = NSHostingController(
            rootView: PopoverView(
                onOpenPanel: { [weak self] in self?.showControlPanel() },
                onHeightChange: { [weak popover] height in
                    DispatchQueue.main.async {
                        popover?.contentSize = NSSize(width: 430, height: height)
                    }
                }
            )
            .environmentObject(model)
        )
        controller.sizingOptions = []
        popover.contentViewController = controller
        self.popover = popover
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: 控制面板

    private func showControlPanel() {
        popover?.performClose(nil)

        if panelWindow == nil {
            let controller = NSHostingController(rootView: ControlPanelView().environmentObject(model))
            let window = NSWindow(contentViewController: controller)
            window.title = "ServerDeck 控制面板"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 720, height: 700))
            window.isReleasedWhenClosed = false
            window.center()
            panelWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        panelWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: 主菜单

    /// LSUIElement 应用默认没有主菜单，补一份最小的“编辑”菜单，
    /// 否则控制面板里的文本框无法使用 ⌘C / ⌘V 等标准快捷键。
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 ServerDeck",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 ServerDeck",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 ServerDeck",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}
