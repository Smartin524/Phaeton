import AppKit
import ApplicationServices
import FormatWheelCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let monitor = DragMonitor()
    private let wheel = DropWheel()
    private let notifier = Notifier()
    private let toolWindows = ToolWindows()
    private let hud = ProgressHUD()
    private var hudShown = false
    private var installing = false
    private let shiftFilter = ShiftFilter()
    private let filterKey = "StripShiftOnSelected"
    private let status = AppStatus()
    private var panel: MenuBarPanel?
    private var pendingFiles: [URL] = []
    /// Held for the app's lifetime: without it macOS naps a windowless app and the 30 Hz drag poll
    /// runs late. It only opts out of App Nap; it does not keep the Mac awake or timers precise, and an
    /// idle app with no timers running costs nothing.
    private var activity: NSObjectProtocol?
    private let welcomedKey = "ShownPanelOnFirstLaunch"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu-bar app: no Dock icon, the wheel icon in the menu bar opens the panel.
        NSApp.setActivationPolicy(.accessory)
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Watching for Shift-drag")
        installMenus()

        wheel.onDrop = { [weak self] urls, format, center in
            self?.model.convert(urls, to: format, at: center)
        }
        wheel.onBatch = { [weak self] urls, action, center in
            self?.model.batch(urls, action: action, at: center)
        }
        wheel.onTools = { [weak self] urls, kind in
            guard let self else { return }
            self.toolWindows.open(urls, kind: kind) { sources, label, work in self.model.perform(sources, label: label, work: work) }
        }
        monitor.onBegin = { [weak self] kind, urls, point in
            guard let self, !self.installing else { return }
            let formats = kind.outputs(for: urls)
            guard !formats.isEmpty else { return }
            // A wrench for everything that has an editor: pictures, video, audio and PDFs.
            let allPDF = urls.allSatisfy { $0.pathExtension.lowercased() == "pdf" }
            self.wheel.show(kind: kind, formats: formats, batch: BatchAction.available(kind: kind, urls: urls),
                            hasTools: kind != .document || allPDF, at: point)
        }
        monitor.onEnd = { [weak self] in
            // Let a drop landing on the wheel finish before hiding it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.wheel.hide() }
        }
        model.onChange = { [weak self] in self?.refresh() }
        hud.onClick = { [weak self] in self?.model.cancel() }
        model.onFinish = { [weak self] message, url, success in
            self?.hud.end(success: success)
            self?.hudShown = false
            self?.notifier.post(message: message, revealing: url, success: success)
        }
        if UserDefaults.standard.bool(forKey: filterKey), AXIsProcessTrusted() { status.shiftFilterOn = shiftFilter.start() }
        model.onNeedExtras = { [weak self] sources, label, work in self?.offerExtras(sources, label, work) }
        model.onCancel = { [weak self] in
            self?.hud.dismiss()
            self?.hudShown = false
        }
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        monitor.start()

        let panel = MenuBarPanel(status: status, actions: HomeActions(
            requestNotifications: { [weak self] in
                Task { @MainActor in
                    await AppStatus.requestNotifications()
                    self?.status.refresh()
                }
            },
            requestAccessibility: { [weak self] in
                self?.status.accessibilityRequested = true
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                AppStatus.openAccessibilitySettings()
            },
            setShiftFilter: { [weak self] on in self?.setShiftFilter(on) },
            close: { [weak self] in self?.panel?.close() },
            quit: { NSApp.terminate(nil) }))
        self.panel = panel
        refresh()
        // On the very first launch (so the app is not invisible) and when the installer asks for it;
        // otherwise, at login included, it stays quiet in the menu bar.
        let asked = CommandLine.arguments.contains("--show-panel")
        if asked || !UserDefaults.standard.bool(forKey: welcomedKey) {
            UserDefaults.standard.set(true, forKey: welcomedKey)
            panel.show()
        }
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) while it runs shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.show()
        return false
    }

    /// A main menu that never shows (the app has no menu bar of its own) but gives text fields in the
    /// editor windows ⌘C / ⌘V / ⌘A / ⌘Z, and the windows ⌘W.
    private func installMenus() {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Phaeton"
        let main = NSMenu()
        func attach(_ submenu: NSMenu) {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        let app = NSMenu()
        app.addItem(withTitle: "关于\(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "隐藏\(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "退出\(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        attach(app)

        let edit = NSMenu(title: "编辑")
        func add(_ title: String, _ action: Selector, _ key: String, shift: Bool = false) {
            let item = edit.addItem(withTitle: title, action: action, keyEquivalent: key)
            if shift { item.keyEquivalentModifierMask = [.command, .shift] }
        }
        add("撤销", Selector(("undo:")), "z")
        add("重做", Selector(("redo:")), "z", shift: true)
        edit.addItem(.separator())
        add("剪切", #selector(NSText.cut(_:)), "x")
        add("拷贝", #selector(NSText.copy(_:)), "c")
        add("粘贴", #selector(NSText.paste(_:)), "v")
        add("全选", #selector(NSText.selectAll(_:)), "a")
        attach(edit)

        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        attach(window)
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isConverting else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "还有任务正在进行"
        alert.informativeText = "现在退出会中断它，未完成的文件可能残留。"
        alert.addButton(withTitle: "继续等待")
        alert.addButton(withTitle: "仍然退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        shiftFilter.stop()
    }

    private func refresh() {
        // The ring appears where the wheel was (or at the pointer for jobs started from a window).
        if model.isConverting {
            if !hudShown {
                hudShown = true
                hud.begin(at: model.origin ?? NSEvent.mouseLocation)
            }
            hud.update(progress: model.progress)
        }
        status.update(\.isConverting, model.isConverting)
        status.update(\.queuedCount, model.queuedCount)
        status.update(\.message, model.message)
        status.update(\.resultURL, model.resultURL)
        panel?.showProgress(model.progress, running: model.isConverting || installing)
    }

    /// The "Shift does not deselect selected files" option (needs Accessibility, which the window asks for).
    private func setShiftFilter(_ on: Bool) {
        if on {
            let started = shiftFilter.start()
            status.shiftFilterOn = started
            UserDefaults.standard.set(started, forKey: filterKey)
        } else {
            shiftFilter.stop()
            status.shiftFilterOn = false
            UserDefaults.standard.set(false, forKey: filterKey)
        }
    }

    /// WebP, MP3 and PDF → DOCX need a one-time download. Ask first, install, then run the job again.
    private func offerExtras(_ sources: [URL], _ label: String, _ work: @escaping ToolWork) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要安装可选组件"
        alert.informativeText = "WebP、MP3 和 PDF 转 Word 需要一次性安装可选组件（约 250 MB，需要联网，从 PyPI 下载到 ~/Library/Application Support/Phaeton，不改动系统）。现在安装吗？"
        alert.addButton(withTitle: "安装")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        installing = true
        hud.begin(at: NSEvent.mouseLocation)
        hud.update(progress: nil)
        refresh()
        Task { @MainActor in
            let failure = await ExtrasInstaller.install()
            installing = false
            hud.end(success: failure == nil)
            if let failure {
                let error = NSAlert()
                error.messageText = "安装失败"
                error.informativeText = failure
                NSApp.activate(ignoringOtherApps: true)
                error.runModal()
            } else {
                model.perform(sources, label: label, work: work)
            }
            refresh()
        }
    }

    /// Asks which format to convert `urls` to, in a menu at the pointer. Used by the
    /// file picker and by the Finder right-click service.
    private func presentFormatMenu(for urls: [URL]) {
        // A job already running is fine: the new one queues behind it, as from the wheel.
        guard let kind = urls.lazy.compactMap({ FileKind($0) }).first else {
            NSSound.beep()
            return
        }
        pendingFiles = urls.filter { FileKind($0) == kind }
        let formats = kind.outputs(for: pendingFiles)
        guard !formats.isEmpty else { return }
        let menu = NSMenu()
        for format in formats {
            let entry = menu.addItem(withTitle: "转为 \(format.title)", action: #selector(convertPending(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = format.rawValue
        }
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Finder right-click ▸ Quick Actions / Services ▸ "用 Phaeton 转换…" (see NSServices in Info.plist).
    @objc func convertFiles(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
        DispatchQueue.main.async { [weak self] in self?.presentFormatMenu(for: urls) }
    }

    @objc private func convertPending(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let format = OutputFormat(rawValue: raw) else { return }
        model.convert(pendingFiles, to: format)
        pendingFiles = []
    }
}
