import AppKit
import UserNotifications
import Combine

struct NotificationEvent: Equatable {
    let id: String
    let kind: String
    let at: Double
}

func notificationEvents(_ session: Session) -> [NotificationEvent] {
    guard session.exitedAt == nil else { return [] }
    var events: [NotificationEvent] = []
    if session.status == "idle", let settled = session.lastSettled, settled.outcome != "aborted" {
        events.append(.init(id: settled.id, kind: "completion", at: settled.at))
    }
    if session.status == "attention", let attention = session.attention {
        events.append(.init(id: attention.id, kind: "attention", at: attention.at))
    }
    return events
}

func isFreshNotificationEvent(_ event: NotificationEvent, launchedAt: Double, wasSeen: Bool) -> Bool {
    event.at > launchedAt && !wasSeen
}

struct AttentionReminderSchedule {
    private struct Entry {
        let eventID: String
        var lastAttemptAt: Double
    }
    private var entries: [String: Entry] = [:]
    private var interval: Double?

    // All times are milliseconds. Reserve each attempt before asynchronous focus checks.
    mutating func due(_ sessions: [Session], now: Double, interval: Double, enabled: Bool) -> [(Session, NotificationEvent)] {
        guard enabled, interval.isFinite, interval > 0 else {
            entries.removeAll(); self.interval = nil
            return []
        }
        if self.interval != interval { entries.removeAll(); self.interval = interval }
        var active: [String: Entry] = [:]
        var reminders: [(Session, NotificationEvent)] = []
        for session in sessions {
            guard let event = notificationEvents(session).first(where: { $0.kind == "attention" }) else { continue }
            var entry = entries[session.runtimeId] ?? Entry(eventID: event.id, lastAttemptAt: now)
            if entry.eventID != event.id || now < entry.lastAttemptAt {
                entry = Entry(eventID: event.id, lastAttemptAt: now)
            }
            if now - entry.lastAttemptAt >= interval {
                reminders.append((session, event))
                entry.lastAttemptAt = now
            }
            active[session.runtimeId] = entry
        }
        entries = active
        return reminders
    }
}

final class SessionNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var permission = "Not requested"
    @Published var authorized = false
    var onOpen: ((Session?) -> Void)?
    var onError: ((String) -> Void)?
    var onPermissionChange: (() -> Void)?
    private let center = UNUserNotificationCenter.current()
    private var identifiers: [String: String] = [:]
    private var lastEvents: [String: String] = [:]

    override init() {
        super.init()
        center.delegate = self
        let open = UNNotificationAction(identifier: "open", title: "Open Session", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: "session", actions: [open], intentIdentifiers: [], options: [.customDismissAction])])
    }
    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            if let error { DispatchQueue.main.async { self?.onError?(error.localizedDescription) } }
            self?.refreshPermission()
        }
    }
    func refreshPermission() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                switch settings.authorizationStatus {
                case .authorized, .provisional: self.permission = "Allowed"
                case .denied: self.permission = "Denied — enable in System Settings"
                default: self.permission = "Not requested"
                }
                self.onPermissionChange?()
            }
        }
    }
    func clear(_ session: Session) {
        let id = "pi-session." + session.sessionId
        identifiers.removeValue(forKey: session.sessionId)
        lastEvents.removeValue(forKey: session.sessionId)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }
    func reconcileDelivered(_ sessions: [Session]) {
        center.getDeliveredNotifications { [weak self] delivered in
            let stale = delivered.filter { notification in
                guard notification.request.identifier.hasPrefix("pi-session.") else { return false }
                let info = notification.request.content.userInfo
                let snapshot = (info["snapshot"] as? String).flatMap { Data(base64Encoded: $0) }
                    .flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
                guard let snapshot, let current = sessions.first(where: { $0.runtimeId == snapshot.runtimeId }),
                      let id = info["event"] as? String else { return true }
                return !notificationEvents(current).contains { $0.id == id }
            }.map { $0.request.identifier }
            self?.center.removeDeliveredNotifications(withIdentifiers: stale)
        }
    }

    func reconcile(_ sessions: [Session], preferences: Preferences) {
        for session in sessions {
            if session.exitedAt != nil || session.status == "busy" ||
                (session.status == "attention" && !preferences.attention) ||
                (session.status == "idle" && (!preferences.completion || session.lastSettled?.outcome == "aborted")) {
                clear(session)
            } else if let previous = lastEvents[session.sessionId],
                      !notificationEvents(session).contains(where: { $0.id == previous }) { clear(session) }
        }
    }
    func post(_ session: Session, event: NotificationEvent, preferences: Preferences, test: Bool = false, reminder: Bool = false) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        let heading = event.kind == "attention" ? (reminder ? "Still needs your attention" : "Needs your attention") : session.lastSettled?.outcome == "error" ? "Run failed" : "Completed"
        content.title = test ? "Pi Sessions notification test" : "\(session.project) · \(heading)"
        content.subtitle = String(session.title.prefix(100))
        content.body = preferences.preview ? String((event.kind == "attention" ? session.attention?.title ?? session.activity : session.lastReply ?? session.displayActivity).prefix(220)) : "Click to open the session in iTerm2."
        if content.body.isEmpty { content.body = "Click to open the session in iTerm2." }
        if preferences.sound { content.sound = .default }
        content.categoryIdentifier = "session"
        if let data = try? JSONEncoder().encode(session) { content.userInfo = ["snapshot": data.base64EncodedString(), "event": event.id] }
        let id = (test ? "pi-test." : "pi-session.") + session.sessionId
        if !test {
            identifiers[session.sessionId] = id
            lastEvents[session.sessionId] = event.id
        }
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { [weak self] error in
            if let error { DispatchQueue.main.async { self?.onError?(error.localizedDescription) } }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.content.sound == nil ? [.banner, .list] : [.banner, .list, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        center.removeDeliveredNotifications(withIdentifiers: [id])
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier || response.actionIdentifier == "open" {
            let value = response.notification.request.content.userInfo["snapshot"] as? String
            let session = value.flatMap { Data(base64Encoded: $0) }.flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
            DispatchQueue.main.async { [weak self] in self?.onOpen?(session) }
        }
        completionHandler()
    }
}
