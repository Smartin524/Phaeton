import AppKit
import ServiceManagement
import SwiftUI

/// What the buttons in the main window can ask the app to do.
struct HomeActions {
    var requestNotifications: () -> Void
    var requestAccessibility: () -> Void
    var setShiftFilter: (Bool) -> Void
    var revealResult: () -> Void
    var quit: () -> Void
}

/// The main window: the app is running, how to use it, and what to allow. Kept short on purpose.
struct HomeView: View {
    @ObservedObject var status: AppStatus
    let actions: HomeActions
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                header
                runningPill
                PanelSection(caption: "开机自启") { launchAtLogin }
                PanelSection(caption: "怎么用") { usage }
                PanelSection(caption: "授权") { permissions }
                footer
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 20)
        }
        .tint(Theme.accent)
        .onReceive(tick) { _ in status.refresh() }
        .task { status.refresh() }
    }

    // MARK: Header and state

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text("轻與").font(.system(size: 24, weight: .semibold))
                Text("Phaeton \(version)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var runningPill: some View {
        HStack(spacing: 8) {
            Circle().fill(status.isConverting ? Theme.accent : Color.green).frame(width: 8, height: 8)
            Text(status.isConverting ? "正在处理文件…" : "已启动，正在后台等待你拖动文件")
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Capsule().fill((status.isConverting ? Theme.accent : Color.green).opacity(0.14)))
    }

    // MARK: Launch at login

    private var launchAtLogin: some View {
        VStack(alignment: .leading, spacing: 8) {
            ListGroup {
                HStack {
                    Text("登录时自动启动").font(.system(size: 12))
                    Spacer()
                    Toggle("", isOn: Binding(get: { status.launchesAtLogin }, set: { status.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            }
            if status.loginStatus == .requiresApproval {
                note("还需要在“系统设置 → 通用 → 登录项”里允许它。") {
                    Button("打开设置") { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(PanelButtonStyle())
                }
            } else if let error = status.loginError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            } else {
                Text("自启后在后台安静运行，不会弹出这个窗口。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: How to use

    private var usage: some View {
        VStack(alignment: .leading, spacing: 8) {
            ListGroup {
                step(1, "按住 Shift，拖动图片、视频、音频、PDF 或文档")
                step(2, "光标处出现轮盘，拖到想要的格式上松手")
                step(3, "拖到正左边的扳手，打开编辑窗口：裁切、剪切、压缩……")
                step(4, "一次拖多个文件，轮盘会多出“合并”或“拼接”", last: true)
            }
            Text("也可以在访达里右键文件 → 快速操作 → 用轻與转换…")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func step(_ number: Int, _ text: String, last: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(Theme.accent))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5).padding(.leading, 40) }
        }
    }

    // MARK: Permissions

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 8) {
            ListGroup {
                permissionRow(symbol: "bell", title: "通知", detail: "转换完成时提醒你，点一下就能看到结果") {
                    switch status.notifications {
                    case .allowed: granted
                    case .notAsked: Button("允许", action: actions.requestNotifications).buttonStyle(PanelButtonStyle())
                    case .denied: Button("打开设置") { AppStatus.openNotificationSettings() }.buttonStyle(PanelButtonStyle())
                    case .unavailable: Text("不可用").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                permissionRow(symbol: "hand.raised", title: "辅助功能（可选）",
                              detail: "只用于让“已选中的文件”也能按 Shift 拖动", last: !status.accessibilityTrusted) {
                    if status.accessibilityTrusted { granted }
                    else { Button("授权", action: actions.requestAccessibility).buttonStyle(PanelButtonStyle()) }
                }
                if status.accessibilityTrusted {
                    HStack {
                        Text("已选中文件时，按 Shift 不取消选中").font(.system(size: 12))
                        Spacer()
                        Toggle("", isOn: Binding(get: { status.shiftFilterOn }, set: actions.setShiftFilter))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                }
            }
            Text("拖动触发本身不需要任何权限，不授权也能正常使用。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var granted: some View {
        Label("已允许", systemImage: "checkmark.circle.fill")
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
    }

    private func permissionRow<Trailing: View>(symbol: String, title: String, detail: String, last: Bool = false,
                                               @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Theme.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5).padding(.leading, 42) }
        }
    }

    private func note<Accessory: View>(_ text: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            accessory()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if status.resultURL != nil {
                Button("在访达中显示最近结果", action: actions.revealResult).buttonStyle(PanelButtonStyle())
            }
            Spacer()
            Button("退出", action: actions.quit).buttonStyle(PanelButtonStyle())
        }
    }
}
