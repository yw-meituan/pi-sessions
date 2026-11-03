import AppKit
import Foundation
import Darwin

func demoSessions() -> [Session] {
    let projects = ["order-service", "dotfiles", "pi-panel", "backend", "web-console", "infra"]
    let tasks = ["Fix order API retry logic", "Clean up development configuration", "Build the session panel", "Check cache consistency", "Improve list filtering", "Debug the deployment script"]
    return (0..<24).map { index in
        let status = index < 2 ? "attention" : index < 10 ? "busy" : "idle"
        var session = Session(version: 1, pid: Int32(1000 + index), processStart: "Fri Oct 30 10:00:00 2026",
            runtimeId: UUID().uuidString, sessionId: "demo-\(index)", cwd: "/Projects/\(projects[index % projects.count])",
            changedAt: Date().timeIntervalSince1970 * 1000 - Double(index) * 65000,
            task: tasks[index % tasks.count], name: nil, model: "test-model",
            status: status, activity: status == "attention" ? "Awaiting plan approval" : status == "busy" ? "Running bash" : "Completed",
            tty: nil, tmux: nil)
        session.lastReply = index < 3 ? "Implementation is ready. Review the changes using the local preview below." : nil
        session.links = index == 0 ? ["http://localhost:3000/review", "http://127.0.0.1:8080/preview"] : []
        if status == "idle" { session.lastSettled = .init(id: UUID().uuidString, at: session.changedAt, outcome: "completed") }
        return session
    }
}

func runSelfTests() {
    checkStatusIcons()
    checkUnreadRows()
    checkAttentionReminders()
    checkKeyboardSelection()
    do {
        let samples = demoSessions()
        precondition(filteredSessions(samples, tab: .attention, query: "").count == 2)
        precondition(filteredSessions(samples, tab: .busy, query: "").count == 8)
        precondition(filteredSessions(samples, tab: .idle, query: "").count == 14)
        precondition(filteredSessions(samples, tab: .all, query: "ORDER missing").isEmpty)
        precondition(filteredSessions(samples, tab: .all, query: "ORDER retry").count == 4)
        let clients = [TmuxClient(tty: "/dev/ttys1", session: "$1", activity: 1),
                       TmuxClient(tty: "/dev/ttys2", session: "$2", activity: 2),
                       TmuxClient(tty: "/dev/ttys3", session: "$1", activity: 3)]
        let plan = try makeFocusPlan(socket: "/tmp/test-socket", pane: "%7", location: ["$1", "@3", "%7", "1"],
            clients: clients, terminalTTYs: ["/dev/ttys1", "/dev/ttys2"])
        precondition(plan.terminalTTY == "/dev/ttys1")
        precondition(plan.commands.contains("resize-pane"))
        precondition(!plan.commands.contains("switch-client"))
        let detached = try makeFocusPlan(socket: "/tmp/test-socket", pane: "%7", location: ["$9", "@4", "%7", "0"],
            clients: clients, terminalTTYs: ["/dev/ttys1", "/dev/ttys2"])
        precondition(detached.terminalTTY == "/dev/ttys2")
        precondition(detached.commands.suffix(6) == [";", "switch-client", "-c", "/dev/ttys2", "-t", "$9"])
        precondition((try? makeFocusPlan(socket: "/tmp/test-socket", pane: "%7", location: ["$1", "@3", "%8", "0"],
            clients: clients, terminalTTYs: ["/dev/ttys1"])) == nil)

        let start = try runProcess("/bin/ps", ["-p", String(getpid()), "-o", "lstart="])
        let current = Session(version: 1, pid: getpid(), processStart: start, runtimeId: UUID().uuidString,
            sessionId: "test", cwd: "/tmp", changedAt: Date().timeIntervalSince1970 * 1000, task: nil, name: nil,
            model: nil, status: "idle", activity: "等待输入", tty: nil, tmux: nil)
        precondition(processIsCurrent(current), "must match the producer's ps start-time format")
        precondition(current.displayActivity == "Ready for input", "legacy producers must display English without a reload")
        var completed = current
        completed.lastSettled = .init(id: UUID().uuidString, at: 200, outcome: "completed")
        completed.lastReply = "Finished the work."
        completed.links = ["http://localhost:3000/review"]
        let events = notificationEvents(completed)
        precondition(events.count == 1)
        precondition(isFreshNotificationEvent(events[0], launchedAt: 100, wasSeen: false))
        precondition(!isFreshNotificationEvent(events[0], launchedAt: 200, wasSeen: false), "startup must not replay historical completions")
        precondition(!isFreshNotificationEvent(events[0], launchedAt: 100, wasSeen: true), "settlement IDs deduplicate notifications")
        var memory = PanelMemory()
        precondition(memory.isUnread(completed))
        memory.readSettlements[completed.sessionId] = completed.lastSettled!.id
        precondition(!memory.isUnread(completed))
        completed.lastSettled = .init(id: UUID().uuidString, at: 201, outcome: "aborted")
        precondition(notificationEvents(completed).isEmpty && !memory.isUnread(completed), "aborts must remain silent")
        completed.exitedAt = 202
        precondition(notificationEvents(completed).isEmpty && SessionTab.exited.includes(completed))
        precondition(safeLocalURL("http://localhost:3000/review") != nil)
        precondition(safeLocalURL("http://[::1]:8080/review") != nil)
        precondition(safeLocalURL("http://127.0.0.1:3000/api/data") == nil)
        precondition(safeLocalURL("http://user:pass@localhost:3000/") == nil)
        precondition(safeLocalURL("http://192.168.0.1:3000/") == nil)
        precondition(safeLocalURL("javascript:alert(1)") == nil)
        let roundTrip = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(completed))
        precondition(roundTrip == completed, "notification snapshots must preserve identity and metadata")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as! [String: Any]
        json["processStart"] = "Thu Jan 1 00:00:00 1970"
        let reused = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
        precondition(!processIsCurrent(reused), "reused PIDs must not appear")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-native-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try JSONEncoder().encode(current).write(to: dir.appendingPathComponent("\(getpid()).json"))
        try Data("broken".utf8).write(to: dir.appendingPathComponent("1234.json"))
        let scanned = try scanSessions(at: dir)
        precondition(scanned == [current], "corrupt state must not hide valid sessions")
        print("Passed: icon rendering/preferences, tabs/search, keyboard selection, focus plans, PID identity, corrupt state isolation, notification deduplication/baseline/aborts, attention reminders, unread state, local URLs, snapshot round-trip")
    } catch { fputs("Self-test failed: \(error)\n", stderr); exit(1) }
}

private func checkAttentionReminders() {
    let domain = "local.pi.sessions.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let preferences = Preferences(defaults: defaults, resolveLoginStatus: false)
    precondition(preferences.repeatAttention && preferences.attentionReminderMinutes == 10)
    preferences.attentionReminderMinutes = 7
    preferences.repeatAttention = false
    let restored = Preferences(defaults: defaults, resolveLoginStatus: false)
    precondition(!restored.repeatAttention && restored.attentionReminderMinutes == 7)
    preferences.attentionReminderMinutes = 0
    precondition(preferences.attentionReminderMinutes == 1 && defaults.integer(forKey: "attentionReminderMinutes") == 1)
    preferences.attentionReminderMinutes = 1441
    precondition(preferences.attentionReminderMinutes == 1440 && defaults.integer(forKey: "attentionReminderMinutes") == 1440)
    defaults.set(-1, forKey: "attentionReminderMinutes")
    precondition(Preferences(defaults: defaults, resolveLoginStatus: false).attentionReminderMinutes == 10)

    let samples = demoSessions()
    var first = samples[0], second = samples[1]
    first.attention = .init(id: "prompt-a", at: -1, title: "Approve?")
    second.attention = .init(id: "prompt-b", at: 300_000, title: "Choose?")
    let interval = 600_000.0
    var schedule = AttentionReminderSchedule()
    precondition(schedule.due([first, samples[2], samples[10]], now: 0, interval: interval, enabled: true).isEmpty, "startup establishes a baseline without replaying old prompts")
    precondition(schedule.due([first, second], now: 300_000, interval: interval, enabled: true).isEmpty)
    precondition(schedule.due([first, second], now: 599_999, interval: interval, enabled: true).isEmpty)
    precondition(schedule.due([first, second], now: 600_000, interval: interval, enabled: true).map { $0.0.id } == [first.id])
    precondition(schedule.due([first, second], now: 600_001, interval: interval, enabled: true).isEmpty, "file events must not duplicate reminders")
    precondition(schedule.due([first, second], now: 900_000, interval: interval, enabled: true).map { $0.0.id } == [second.id], "each session has its own clock")
    precondition(schedule.due([first, second], now: 900_001, interval: interval, enabled: false).isEmpty)
    precondition(schedule.due([first, second], now: 900_002, interval: interval, enabled: true).isEmpty)
    precondition(schedule.due([first, second], now: 1_500_001, interval: interval, enabled: true).isEmpty)
    precondition(schedule.due([first, second], now: 1_500_002, interval: interval, enabled: true).count == 2)
    precondition(schedule.due([first, second], now: 1_500_003, interval: 120_000, enabled: true).isEmpty, "interval edits start a new countdown")
    precondition(schedule.due([first, second], now: 1_620_003, interval: 120_000, enabled: true).count == 2)
    precondition(schedule.due([first, second], now: 9_000_000, interval: 120_000, enabled: true).count == 2, "wake from sleep sends at most one reminder per session")
    precondition(schedule.due([first, second], now: 9_000_001, interval: 120_000, enabled: true).isEmpty)

    first.attention = .init(id: "new-prompt", at: 9_100_000, title: "New question")
    second.exitedAt = 9_100_000
    precondition(schedule.due([first, second], now: 9_120_000, interval: 120_000, enabled: true).isEmpty, "new prompts reset the clock and exited sessions stop reminding")
    precondition(schedule.due([samples[2], samples[10]], now: 9_240_000, interval: 120_000, enabled: true).isEmpty, "busy and idle sessions do not repeat")
    precondition(schedule.due([first], now: 9_360_000, interval: 120_000, enabled: true).isEmpty, "a departed prompt must lose its timer")
    precondition(schedule.due([first], now: 9_480_000, interval: 120_000, enabled: true).count == 1)
    precondition(schedule.due([first], now: 0, interval: 120_000, enabled: true).isEmpty, "clock rollback resets the baseline")
    precondition(schedule.due([first], now: 120_000, interval: 120_000, enabled: true).count == 1)
}

private func checkKeyboardSelection() {
    var selection = SessionKeyboardSelection()
    precondition(selection.resolved(in: []) == nil)
    precondition(selection.resolved(in: ["a", "b", "c"]) == "a")
    selection.move(-1, in: ["a", "b", "c"])
    precondition(selection.id == "a", "up at the first row must not wrap")
    selection.move(1, in: ["a", "b", "c"])
    precondition(selection.id == "b")
    precondition(selection.resolved(in: ["c", "a", "b"]) == "b", "reordering must preserve the selected runtime")
    selection.move(1, in: ["c", "a", "b"])
    precondition(selection.id == "b", "down at the last row must not wrap")
    precondition(selection.resolved(in: ["c", "a"]) == "c", "a removed selection falls back to the first live row")
    selection.id = nil
    precondition(selection.resolved(in: ["a", "b"]) == "a", "filter reset selects the first result")
    selection.move(1, in: [])
    precondition(selection.id == nil)
}

private func checkUnreadRows() {
    let domain = "local.pi.sessions.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let preferences = Preferences(defaults: defaults, resolveLoginStatus: false)
    var samples = demoSessions()
    var memory = PanelMemory()
    for session in samples where session.lastSettled != nil {
        memory.readSettlements[session.sessionId] = session.lastSettled!.id
    }
    for index in [11, 12] { memory.readSettlements.removeValue(forKey: samples[index].sessionId) }
    memory.pins.insert(samples[10].sessionId)
    let store = SessionStore(memory: memory, preferences: preferences)
    store.sessions = samples
    precondition(store.unreadCount == 2)
    let ordered = store.rows(tab: .all, query: "")
    precondition(Array(ordered.prefix(4).map(\.sessionId)) == ["demo-0", "demo-1", "demo-11", "demo-12"], "attention and unread must not be buried by recent or pinned read sessions")
    precondition(store.rows(tab: .all, query: "", unreadOnly: true).map(\.sessionId) == ["demo-11", "demo-12"], "filter changes must invalidate the row cache")
    precondition(store.rows(tab: .all, query: "order", unreadOnly: true).map(\.sessionId) == ["demo-12"])
    precondition(store.rows(tab: .busy, query: "", unreadOnly: true).isEmpty)
    store.togglePin(samples[12])
    precondition(store.rows(tab: .all, query: "", unreadOnly: true).first?.sessionId == "demo-12")
    store.markRead(samples[12])
    precondition(store.rows(tab: .all, query: "", unreadOnly: true).map(\.sessionId) == ["demo-11"], "mark read must immediately remove a cached unread row")
    precondition(store.rows(tab: .idle, query: "").first?.sessionId == "demo-11")
    store.markAllRead()
    precondition(store.unreadCount == 0 && store.rows(tab: .all, query: "", unreadOnly: true).isEmpty)
    samples[12].lastSettled = .init(id: UUID().uuidString, at: samples[12].changedAt + 1, outcome: "completed")
    store.sessions = samples
    precondition(store.rows(tab: .all, query: "", unreadOnly: true).map(\.sessionId) == ["demo-12"], "a new completion must reappear after mark all read")
}

private func checkStatusIcons() {
    let domain = "local.pi.sessions.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let preferences = Preferences(defaults: defaults, resolveLoginStatus: false)
    precondition(preferences.iconStyle == .official, "new installations default to official artwork")
    var changed: StatusIconStyle?
    preferences.onChange = { [weak preferences] in changed = preferences?.iconStyle }
    preferences.iconStyle = .lucide
    precondition(changed == .lucide, "icon changes must notify the status item immediately")
    precondition(Preferences(defaults: defaults, resolveLoginStatus: false).iconStyle == .lucide, "icon choice must survive reload")
    for obsolete in ["unknown-icon", "terminal", "sparkles", "sessions", "bolt", "pi", "rounded", "bold", "outline", "circle"] {
        defaults.set(obsolete, forKey: "statusIcon")
        precondition(Preferences(defaults: defaults, resolveLoginStatus: false).iconStyle == .official, "removed styles must fall back to official artwork")
    }
    for style in StatusIconStyle.allCases {
        if let name = style.assetName {
            precondition(Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "icons") != nil, "missing bundled icon: \(name)")
        }
        for indicator in [false, true] {
            guard let image = makeStatusIcon(style: style, indicator: indicator),
                  let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) else {
                preconditionFailure("icon cannot render: \(style)")
            }
            precondition(image.isTemplate == (style != .official) && image.size.height == 18 && image.size.width > 0)
            if style == .official {
                precondition((0..<bitmap.pixelsWide).contains { x in
                    (0..<bitmap.pixelsHigh).contains { y in
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { return false }
                        return abs(color.redComponent - color.blueComponent) > 0.2
                    }
                }, "official artwork must retain its colors")
            }
            precondition((0..<bitmap.pixelsWide).contains { x in
                (0..<bitmap.pixelsHigh).contains { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 }
            }, "icon must not be blank: \(style)")
        }
    }
}
