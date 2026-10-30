import AppKit
import SwiftUI
import UserNotifications

final class SessionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = SessionStore()
    var statusItem: NSStatusItem?
    var panel: SessionPanel!
    private var outsideClick: Any?
    private var hotKey: PanelHotKey?
    private var shortcutChoice = ""
    private var indicatorShown: Bool?
    private var iconShown: StatusIconStyle?
    private var hostingView: NSHostingView<PanelView>!
    private let renderPath: String?

    init(renderPath: String? = nil) { self.renderPath = renderPath }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = SessionPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.title = "Pi Sessions"
        hostingView = NSHostingView(rootView: PanelView(store: store, preferences: store.preferences,
            onSelect: { [weak self] session in self?.hidePanel(); self?.store.focus(session) },
            onClose: { [weak self] in self?.hidePanel() },
            onQuit: { NSApp.terminate(nil) }))
        panel.contentView = hostingView
        store.onFocusFailure = { [weak self] in self?.showPanel() }
        store.onNotificationOpen = { [weak self] session in
            guard let self else { return }
            if let session { self.hidePanel(); self.store.focus(session) } else { self.showPanel() }
        }
        if let renderPath {
            store.sessions = demoSessions()
            store.memory.pins.insert("demo-0")
            showPanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.render(to: renderPath) }
            return
        }
        let defaults = UserDefaults.standard
        let positionKey = "NSStatusItem Preferred Position PiSessions"
        if defaults.object(forKey: positionKey) == nil { defaults.set(180, forKey: positionKey) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "PiSessions"
        item.button?.title = ""
        item.button?.imagePosition = .imageOnly
        item.button?.image = makeStatusIcon(style: store.preferences.iconStyle)
        item.button?.contentTintColor = nil
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item
        store.onChange = { [weak self] in self?.updateStatus() }
        hotKey = PanelHotKey()
        hotKey?.onPress = { [weak self] in self?.togglePanel() }
        store.preferences.onChange = { [weak self] in
            self?.store.preferencesChanged(); self?.configureShortcut()
        }
        configureShortcut()
        do { try store.start() } catch { store.error = error.localizedDescription }
        updateStatus()
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showPanel() }
        }
    }

    private func configureShortcut() {
        let choice = store.preferences.shortcut
        guard choice != shortcutChoice else { return }
        do { try hotKey?.configure(choice); shortcutChoice = choice }
        catch { store.error = error.localizedDescription }
    }

    func updateStatus() {
        let count = store.liveSessions.count
        statusItem?.button?.setAccessibilityLabel("Pi Sessions, \(count) sessions")
        let attention = store.liveSessions.filter { $0.status == "attention" }.count
        let busy = store.liveSessions.filter { $0.status == "busy" }.count
        let indicator = store.preferences.indicator && (attention > 0 || store.unreadCount > 0)
        let icon = store.preferences.iconStyle
        if indicatorShown != indicator || iconShown != icon {
            statusItem?.button?.image = makeStatusIcon(style: icon, indicator: indicator)
            indicatorShown = indicator
            iconShown = icon
        }
        statusItem?.button?.toolTip = "Pi Sessions · Attention \(attention) · Running \(busy) · Idle \(count - attention - busy) · Unread \(store.unreadCount)"
    }

    @objc func togglePanel() { panel.isVisible ? hidePanel() : showPanel() }

    func showPanel() {
        if !panel.isVisible { store.observeCurrent(wasITerm: NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.googlecode.iterm2") }
        if renderPath == nil { store.refresh() }
        let mouse = NSEvent.mouseLocation
        let screen = statusItem?.button?.window?.screen ?? NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        let width: CGFloat = min(520, screen.visibleFrame.width - 24)
        let height: CGFloat = min(520, screen.visibleFrame.height - 40)
        let frame: NSRect
        if let button = statusItem?.button, let window = button.window, window.isVisible,
           window.occlusionState.contains(.visible) {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            let x = max(screen.visibleFrame.minX + 8, min(anchor.midX - width / 2, screen.visibleFrame.maxX - width - 8))
            frame = NSRect(x: x, y: anchor.minY - height - 5, width: width, height: height)
        } else {
            frame = NSRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.midY - height / 2, width: width, height: height)
        }
        panel.setFrame(frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .init("PiSessionsFocusSearch"), object: nil)
        if outsideClick == nil {
            outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.hidePanel()
            }
        }
    }

    func hidePanel() {
        panel.orderOut(nil)
        if let outsideClick { NSEvent.removeMonitor(outsideClick); self.outsideClick = nil }
    }
    func windowDidResignKey(_ notification: Notification) { hidePanel() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return false }
    func applicationWillTerminate(_ notification: Notification) { hidePanel() }

    private func render(to path: String) {
        hostingView.layoutSubtreeIfNeeded()
        guard let image = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { exit(1) }
        hostingView.cacheDisplay(in: hostingView.bounds, to: image)
        do {
            guard let data = image.representation(using: .png, properties: [:]) else { exit(1) }
            try data.write(to: URL(fileURLWithPath: path))
            print("Rendered \(Int(hostingView.bounds.width))×\(Int(hostingView.bounds.height)): \(path)")
            NSApp.terminate(nil)
        } catch { fputs("\(error)\n", stderr); exit(1) }
    }
}

@main
struct PiSessionsMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--notification-status") {
            let done = DispatchSemaphore(value: 0)
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                print("Notification authorization: \(settings.authorizationStatus.rawValue) (0=not requested, 1=denied, 2=allowed)")
                print("Alerts: \(settings.alertSetting.rawValue), sound: \(settings.soundSetting.rawValue)")
                done.signal()
            }
            if done.wait(timeout: .now() + 5) == .timedOut { fputs("Notification settings query timed out\n", stderr); exit(1) }
            return
        }
        if args.contains("--self-test") { runSelfTests(); return }
        if let index = args.firstIndex(of: "--validate-state"), index + 1 < args.count {
            do {
                let session = try readSession(URL(fileURLWithPath: args[index + 1]))
                print(String(decoding: try JSONEncoder().encode(session), as: UTF8.self))
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if args.contains("--diagnose") {
            do {
                let sessions = try scanSessions()
                print("Live sessions: \(sessions.count)")
                for session in sessions { print("\(session.pid)\t\(session.status)\t\(session.project)\t\(session.title)") }
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let renderIndex = args.firstIndex(of: "--render-demo")
        let renderPath = renderIndex.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let application = NSApplication.shared
        if renderPath == nil, let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != getpid() }) {
            NSWorkspace.shared.openApplication(at: other.bundleURL!, configuration: .init())
            return
        }
        let delegate = AppDelegate(renderPath: renderPath)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
