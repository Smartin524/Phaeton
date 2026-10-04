import AppKit
import ApplicationServices
import ServiceManagement
import UserNotifications

enum NotificationState { case allowed, notAsked, denied, unavailable }

/// What the menu-bar panel shows: whether a job is running, the last result, and the state of each
/// permission. The panel refreshes it every second while it is open (and never while it is closed),
/// so a switch made in System Settings shows up without reopening anything.
@MainActor
final class AppStatus: ObservableObject {
    @Published var isConverting = false
    @Published var queuedCount = 0
    @Published var message = ""
    @Published var resultURL: URL?
    @Published var notifications = NotificationState.unavailable
    @Published var accessibilityTrusted = false
    /// Set once the user has pressed "授权", so a stale entry can be explained if it still is not trusted.
    @Published var accessibilityRequested = false
    @Published var shiftFilterOn = false
    /// The wheel icon in the menu bar; on unless turned off in the panel.
    @Published var showsMenuBarIcon = UserDefaults.standard.object(forKey: MenuBarPanel.iconKey) as? Bool ?? true
    @Published var loginStatus = SMAppService.Status.notRegistered
    @Published var loginError: String?

    /// Assigning a @Published property announces a change even when the value is the same, and every
    /// announcement re-renders the panel; so only changed values are written.
    func refresh() {
        update(\.accessibilityTrusted, AXIsProcessTrusted())
        update(\.loginStatus, SMAppService.mainApp.status)
        Task {
            let state = await Self.notificationState()
            update(\.notifications, state)
        }
    }

    func update<Value: Equatable>(_ key: ReferenceWritableKeyPath<AppStatus, Value>, _ value: Value) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    /// Registers or removes the app as a login item (System Settings ▸ General ▸ Login Items).
    func setLaunchAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = SMAppService.mainApp.status
    }

    var launchesAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    static func notificationState() async -> NotificationState {
        guard Bundle.main.bundleIdentifier != nil else { return .unavailable }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .notDetermined: return .notAsked
        case .denied: return .denied
        @unknown default: return .unavailable
        }
    }

    static func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
    }

    static func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        open("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)",
             fallback: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
             fallback: "x-apple.systempreferences:com.apple.preference.security")
    }

    private static func open(_ url: String, fallback: String) {
        if let target = URL(string: url), NSWorkspace.shared.open(target) { return }
        if let target = URL(string: fallback) { NSWorkspace.shared.open(target) }
    }
}
