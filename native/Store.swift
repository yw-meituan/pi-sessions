import AppKit
import Combine
import Darwin

final class SessionStore: ObservableObject {
    @Published var sessions: [Session] = [] {
        didSet { cachedLive = nil; cachedRows = nil; cachedLinks = nil }
    }
    @Published var error: String?
    @Published var focusing = false
    @Published var now = Date()
    @Published var memory: PanelMemory {
        didSet {
            cachedLinks = nil
            if memory.pins != oldValue.pins || memory.readSettlements != oldValue.readSettlements { cachedRows = nil }
            if memory.seenEvents != oldValue.seenEvents {
                updateRememberedEvents(previous: oldValue.seenEvents, current: memory.seenEvents)
            }
        }
    }
    @Published var currentRuntimeID: String?
    @Published var notice: String?
    let preferences: Preferences
    var notifications: SessionNotifications?
    var onChange: (() -> Void)?
    var onFocusFailure: (() -> Void)?
    var onNotificationOpen: ((Session?) -> Void)?
    private let launchedAt = Date().timeIntervalSince1970 * 1000
    private let queue = DispatchQueue(label: "pi.sessions.scan", qos: .utility)
    private let focusQueue = DispatchQueue(label: "pi.sessions.focus", qos: .userInitiated)
    private let observationQueue = DispatchQueue(label: "pi.sessions.observation", qos: .utility)
    private var focusGeneration = 0
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var timer: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var lastLive: [Session] = []
    private let history = SessionHistoryReader()
    private var ownerStart = ""
    private var canPersist = false
    private var reconciledDelivered = false
    private var attentionReminders = AttentionReminderSchedule()
    private var cachedLive: [Session]?
    private struct RowsSnapshot {
        let tab: SessionTab
        let query: String
        let unreadOnly: Bool
        let showExited: Bool
        let locale: Locale
        let rows: [Session]
    }
    private var cachedRows: RowsSnapshot?
    private struct LinksSnapshot {
        let sessionID: String
        let source: [String]
        let links: [String]
    }
    private var cachedLinks: LinksSnapshot?
    private var rememberedEventIDs: Set<String>?

    init(memory: PanelMemory = PanelMemory.load(), preferences: Preferences = Preferences()) {
        self.memory = memory
        self.preferences = preferences
        rememberedEventIDs = memory.seenEvents.count <= PanelMemory.seenEventLimit ? Set(memory.seenEvents) : nil
    }

    var liveSessions: [Session] {
        if let cachedLive { return cachedLive }
        let live = sessions.filter { $0.exitedAt == nil }
        cachedLive = live
        return live
    }
    var visibleSessions: [Session] { preferences.showExited ? sessions : liveSessions }
    var unreadCount: Int {
        let memory = memory
        return liveSessions.reduce(0) { $0 + (memory.isUnread($1) ? 1 : 0) }
    }
    func rows(tab: SessionTab, query: String, unreadOnly: Bool = false) -> [Session] {
        let locale = Locale.current
        if let cachedRows, cachedRows.tab == tab, cachedRows.query == query, cachedRows.unreadOnly == unreadOnly,
           cachedRows.showExited == preferences.showExited, cachedRows.locale == locale { return cachedRows.rows }
        let filtered = filteredSessions(visibleSessions, tab: tab, query: query)
        // Keep attention first, then unread completions; pins lead within each group.
        var groups = Array(repeating: [Session](), count: 6)
        for session in filtered {
            let unread = memory.isUnread(session)
            if unreadOnly && !unread { continue }
            let priority = session.effectiveStatus == "attention" ? 0 : unread ? 1 : 2
            let pin = memory.pins.contains(session.sessionId) ? 0 : 1
            groups[priority * 2 + pin].append(session)
        }
        let rows = groups.flatMap { $0 }
        cachedRows = RowsSnapshot(tab: tab, query: query, unreadOnly: unreadOnly, showExited: preferences.showExited, locale: locale, rows: rows)
        return rows
    }

    func start() throws {
        canPersist = true
        ownerStart = (try? runProcess("/bin/ps", ["-p", String(getpid()), "-o", "lstart="])) ?? ""
        let notifications = SessionNotifications()
        self.notifications = notifications
        notifications.onOpen = { [weak self] session in self?.onNotificationOpen?(session) }
        notifications.onError = { [weak self] message in self?.error = message }
        notifications.onPermissionChange = { [weak self] in self?.writeOwner() }
        for directory in [sessionsDirectory, exitedDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fd = open(directory.path, O_EVTONLY)
            guard fd >= 0 else { throw PanelError("Cannot watch the session directory") }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
            source.setCancelHandler { close(fd) }
            source.setEventHandler { [weak self] in
                if directory == exitedDirectory { self?.history.invalidate() }
                self?.scheduleScan()
            }
            source.resume(); watchers.append(source)
        }
        _ = try cleanStaleStates()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 15, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.history.invalidate(); self?.scan() }
        timer.resume(); self.timer = timer
        if preferences.completion || preferences.attention { notifications.requestPermission() } else { notifications.refreshPermission() }
    }

    func preferencesChanged() {
        objectWillChange.send()
        notifications?.reconcile(sessions, preferences: preferences)
        remindAttention(at: Date().timeIntervalSince1970 * 1000)
        writeOwner(); onChange?()
    }
    private func writeOwner() {
        guard canPersist else { return }
        struct Owner: Codable { let pid: Int32; let processStart: String; let enabled: Bool }
        let enabled = notifications?.authorized == true || (!preferences.completion && !preferences.attention)
        try? savePrivate(Owner(pid: getpid(), processStart: ownerStart, enabled: enabled),
                         to: supportDirectory.appendingPathComponent("notification-owner.json"))
    }
    func refresh() { guard canPersist else { return }; queue.async { [weak self] in self?.history.invalidate(); self?.scan() } }
    private func scheduleScan() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        pending = work; queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    private func scan() {
        do {
            let live = try scanSessions()
            for old in lastLive where !live.contains(where: { $0.runtimeId == old.runtimeId || $0.pid == old.pid }) && !processIsCurrent(old) {
                try archiveSnapshot(old)
                history.invalidate()
            }
            lastLive = live
            let ids = Set(live.map(\.sessionId))
            let exited = history.load().filter { !ids.contains($0.sessionId) }
            DispatchQueue.main.async { [weak self] in self?.apply(live + exited) }
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.error = message }
        }
    }
    private func sameEventWindow(_ lhs: ArraySlice<String>, _ rhs: ArraySlice<String>) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in
                for index in left.indices where left[index] != right[index] { return false }
                return true
            }
        }
    }

    private func updateRememberedEvents(previous: [String], current: [String]) {
        guard current.count <= PanelMemory.seenEventLimit else { rememberedEventIDs = nil; return }
        // Verify the entire append/eviction shape; arbitrary memory replacement still rebuilds.
        if rememberedEventIDs != nil, current.count == previous.count + 1,
           sameEventWindow(current.dropLast(), previous[...]) {
            rememberedEventIDs!.insert(current.last!)
        } else if current.count == PanelMemory.seenEventLimit, previous.count == current.count,
                  rememberedEventIDs?.count == previous.count,
                  sameEventWindow(current.dropLast(), previous.dropFirst()) {
            rememberedEventIDs!.remove(previous.first!)
            rememberedEventIDs!.insert(current.last!)
        } else {
            rememberedEventIDs = Set(current)
        }
    }

    private func hasSeenEvent(_ id: String) -> Bool {
        rememberedEventIDs?.contains(id) ?? memory.seenEvents.contains(id)
    }

    func apply(_ result: [Session]) {
        let hidden = memory.hiddenExited
        let visible = hidden.isEmpty ? result : result.filter { $0.exitedAt == nil || !hidden.contains($0.runtimeId) }
        if sessions != visible { sessions = visible }
        now = Date()
        notifications?.reconcile(result, preferences: preferences)
        if !reconciledDelivered { notifications?.reconcileDelivered(result); reconciledDelivered = true }
        var changed = false
        for session in result where session.exitedAt == nil {
            for event in notificationEvents(session) where !hasSeenEvent(event.id) {
                // The loop already excluded remembered IDs; don't rebuild the entire set.
                let fresh = isFreshNotificationEvent(event, launchedAt: launchedAt, wasSeen: false)
                memory.remember(event.id); changed = true
                guard fresh,
                      (event.kind == "attention" ? preferences.attention : preferences.completion) else { continue }
                dispatchNotification(session, event: event)
            }
        }
        if changed { persist() }
        remindAttention(at: now.timeIntervalSince1970 * 1000)
        onChange?()
    }
    private func remindAttention(at time: Double) {
        let reminders = attentionReminders.due(sessions, now: time,
            interval: Double(preferences.attentionReminderMinutes) * 60_000,
            enabled: preferences.attention && preferences.repeatAttention && notifications?.authorized == true)
        for (session, event) in reminders {
            dispatchNotification(session, event: event, reminderInterval: preferences.attentionReminderMinutes)
        }
    }
    private func dispatchNotification(_ session: Session, event: NotificationEvent, reminderInterval: Int? = nil) {
        let checkCurrent = preferences.suppressCurrent && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.googlecode.iterm2"
        let live = liveSessions
        observationQueue.async { [weak self] in
            let current = checkCurrent ? TerminalFocus().visibleSessionID(live) : nil
            DispatchQueue.main.async {
                guard let self, let latest = self.sessions.first(where: { $0.runtimeId == session.runtimeId }),
                      notificationEvents(latest).contains(where: { $0.id == event.id }),
                      (event.kind == "attention" ? self.preferences.attention : self.preferences.completion) else { return }
                if let reminderInterval {
                    guard self.preferences.repeatAttention, self.preferences.attentionReminderMinutes == reminderInterval else { return }
                }
                if current == session.runtimeId { self.markRead(latest); return }
                self.notifications?.post(latest, event: event, preferences: self.preferences, reminder: reminderInterval != nil)
            }
        }
    }
    func observeCurrent(wasITerm: Bool) {
        currentRuntimeID = nil
        guard wasITerm else { return }
        let live = liveSessions
        let generation = focusGeneration
        observationQueue.async { [weak self] in
            let current = TerminalFocus().visibleSessionID(live)
            DispatchQueue.main.async {
                guard let self, self.focusGeneration == generation else { return }
                self.currentRuntimeID = current
            }
        }
    }
    func focus(_ session: Session) {
        guard !focusing else { return }
        if session.exitedAt != nil { error = "This session has exited. Right-click to copy its resume command."; onFocusFailure?(); return }
        focusing = true; error = nil
        focusGeneration += 1
        focusQueue.async { [weak self] in
            var message: String?
            do { try TerminalFocus().focus(session) } catch { message = error.localizedDescription }
            let failure = message
            DispatchQueue.main.async {
                guard let self else { return }
                self.focusing = false; self.error = failure
                if failure != nil { self.onFocusFailure?() } else { self.markRead(session); self.currentRuntimeID = session.runtimeId }
                self.refresh()
            }
        }
    }
    func markRead(_ session: Session) {
        if let settled = session.lastSettled { memory.readSettlements[session.sessionId] = settled.id }
        notifications?.clear(session); persist(); onChange?()
    }
    func markAllRead() { for session in liveSessions { markRead(session) } }
    func togglePin(_ session: Session) {
        if memory.pins.contains(session.sessionId) { memory.pins.remove(session.sessionId) } else { memory.pins.insert(session.sessionId) }
        persist()
    }
    func links(for session: Session) -> [String] {
        guard let source = session.links, !source.isEmpty else { return [] }
        if let cachedLinks, cachedLinks.sessionID == session.sessionId, cachedLinks.source.count == source.count,
           zip(cachedLinks.source, source).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }) { return cachedLinks.links }
        let removed = memory.removedLinks[session.sessionId] ?? []
        let uses = memory.linkUses
        let links = source.reversed().filter { safeLocalURL($0) != nil && !removed.contains($0) }
            .sorted { uses[$0, default: 0] > uses[$1, default: 0] }
        cachedLinks = LinksSnapshot(sessionID: session.sessionId, source: source, links: links)
        return links
    }
    func openLink(_ value: String) {
        guard let url = safeLocalURL(value) else { error = "This is not an allowed local service URL."; return }
        memory.linkUses[value, default: 0] += 1; persist(); NSWorkspace.shared.open(url)
    }
    func removeLink(_ value: String, from session: Session) {
        memory.removedLinks[session.sessionId, default: []].insert(value); persist()
    }
    func removeAllLinks(_ session: Session) { memory.removedLinks[session.sessionId] = Set(session.links ?? []); persist() }
    func removeExited(_ session: Session) {
        guard session.exitedAt != nil else { return }
        memory.hiddenExited.insert(session.runtimeId)
        if memory.hiddenExited.count > 200 { memory.hiddenExited = Set(memory.hiddenExited.prefix(200)) }
        sessions.removeAll { $0.runtimeId == session.runtimeId }; persist()
        queue.async { [weak self] in
            try? FileManager.default.removeItem(at: exitedDirectory.appendingPathComponent("\(session.runtimeId).json"))
            self?.history.invalidate()
        }
    }
    func cleanup() {
        queue.async { [weak self] in
            do {
                let count = try cleanStaleStates()
                _ = loadExited()
                DispatchQueue.main.async { self?.notice = "Removed \(count) stale live-state files. History is kept for 7 days (up to 100 sessions)."; self?.refresh() }
            } catch { let message = error.localizedDescription; DispatchQueue.main.async { self?.error = message } }
        }
    }
    func testNotification() {
        guard let session = liveSessions.first else { error = "Open a Pi session first, then send a test notification."; return }
        guard notifications?.authorized == true else { notifications?.requestPermission(); return }
        notifications?.post(session, event: .init(id: UUID().uuidString, kind: "completion", at: now.timeIntervalSince1970 * 1000), preferences: preferences, test: true)
        notice = "Test notification submitted. Click it to verify terminal focus. macOS Focus settings may silence banners."
    }
    private func persist() {
        guard canPersist else { return }
        do { try savePrivate(memory, to: PanelMemory.url) } catch { self.error = error.localizedDescription }
    }
    deinit { watchers.forEach { $0.cancel() }; timer?.cancel(); pending?.cancel() }
}
