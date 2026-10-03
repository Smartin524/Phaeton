import AppKit
import FormatWheelCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let monitor = DragMonitor()
    private let wheel = DropWheel()
    private let notifier = Notifier()
    private let toolWindows = ToolWindows()
    private let hud = ProgressHUD()
    private var hudCenter: NSPoint?
    private var hudShown = false
    private var installing = false
    private let shiftFilter = ShiftFilter()
    private var filterItem: NSMenuItem?
    private let filterKey = "StripShiftOnSelected"
    private var statusItem: NSStatusItem?
    private var pendingFiles: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "Phaeton"
        let icon = NSImage(systemSymbolName: "chart.pie", accessibilityDescription: "Phaeton")
        icon?.isTemplate = true
        item.button?.image = icon
        // Deliberately tiny: everything else happens by dragging, from Finder's right-click menu,
        // or by clicking the progress ring.
        let menu = NSMenu()
        menu.autoenablesItems = false
        let filter = menu.addItem(withTitle: "已选中文件时 Shift 不取消选中", action: #selector(toggleShiftFilter), keyEquivalent: "")
        filter.target = self
        filterItem = filter
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Phaeton", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item

        wheel.onDrop = { [weak self] urls, format, center in
            self?.hudCenter = center
            self?.model.convert(urls, to: format)
        }
        wheel.onBatch = { [weak self] urls, action, center in
            self?.hudCenter = center
            self?.model.batch(urls, action: action)
        }
        wheel.onTools = { [weak self] urls, kind in
            guard let self else { return }
            self.toolWindows.open(urls, kind: kind) { sources, label, work in self.model.perform(sources, label: label, work: work) }
        }
        monitor.onBegin = { [weak self] kind, urls, point in
            guard let self, !self.model.isConverting, !self.installing else { return }
            let formats = kind.outputs(for: urls)
            guard !formats.isEmpty else { return }
            // A wrench for everything that has an editor: pictures, video, audio and PDFs.
            let allPDF = urls.allSatisfy { $0.pathExtension.lowercased() == "pdf" }
            self.wheel.show(kind: kind, formats: formats, batch: BatchAction.available(kind: kind, urls: urls),
                            hasTools: kind != .document || allPDF, count: urls.count, at: point)
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
            self?.hudCenter = nil
            self?.notifier.post(message: message, revealing: url, success: success)
        }
        if UserDefaults.standard.bool(forKey: filterKey) { filterItem?.state = shiftFilter.start() ? .on : .off }
        model.onNeedExtras = { [weak self] sources, label, work in self?.offerExtras(sources, label, work) }
        model.onCancel = { [weak self] in
            self?.hud.dismiss()
            self?.hudShown = false
            self?.hudCenter = nil
        }
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        monitor.start()
        refresh()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.isConverting ? .terminateCancel : .terminateNow
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
                hud.begin(at: hudCenter ?? NSEvent.mouseLocation)
            }
            hud.update(progress: model.progress)
        }
        statusItem?.button?.toolTip = model.message
        if let progress = model.progress {
            statusItem?.button?.title = " \(Int(progress * 100))%"
        } else {
            statusItem?.button?.title = model.isConverting ? " …" : ""
        }
    }

    /// Needs Accessibility permission. If it is missing the system asks; the switch stays off
    /// until the permission exists and the item is chosen again.
    @objc private func toggleShiftFilter() {
        if shiftFilter.isRunning {
            shiftFilter.stop()
            UserDefaults.standard.set(false, forKey: filterKey)
            filterItem?.state = .off
        } else if shiftFilter.start() {
            UserDefaults.standard.set(true, forKey: filterKey)
            filterItem?.state = .on
        } else {
            UserDefaults.standard.set(false, forKey: filterKey)
            filterItem?.state = .off
            let alert = NSAlert()
            alert.messageText = "需要辅助功能权限"
            alert.informativeText = "请在“系统设置 → 隐私与安全性 → 辅助功能”里允许 Phaeton，然后再次选择此项。Phaeton 只在你对访达里已选中的文件按住 Shift 点击时，去掉那一次点击的 Shift 标记。"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
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
        hud.begin(at: hudCenter ?? NSEvent.mouseLocation)
        hud.update(progress: nil)
        statusItem?.button?.toolTip = "正在安装可选组件…"
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
        guard !model.isConverting, let kind = urls.lazy.compactMap({ FileKind($0) }).first else {
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

    @objc private func quit() {
        guard !model.isConverting else { NSSound.beep(); return }
        NSApp.terminate(nil)
    }
}
