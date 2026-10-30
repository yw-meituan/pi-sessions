import AppKit
import Combine
import ServiceManagement

let supportDirectory = sessionsDirectory.deletingLastPathComponent()
let exitedDirectory = supportDirectory.appendingPathComponent("exited", isDirectory: true)

func savePrivate<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(value).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

final class Preferences: ObservableObject {
    private let defaults: UserDefaults
    private let persistChanges: Bool
    var onChange: (() -> Void)?
    @Published var completion: Bool { didSet { changed("notifyCompletion", completion) } }
    @Published var attention: Bool { didSet { changed("notifyAttention", attention) } }
    @Published var sound: Bool { didSet { changed("notificationSound", sound) } }
    @Published var preview: Bool { didSet { changed("notificationPreview", preview) } }
    @Published var suppressCurrent: Bool { didSet { changed("suppressCurrent", suppressCurrent) } }
    @Published var showExited: Bool { didSet { changed("showExited", showExited) } }
    @Published var indicator: Bool { didSet { changed("statusIndicator", indicator) } }
    @Published var iconStyle: StatusIconStyle { didSet { changed("statusIcon", iconStyle.rawValue) } }
    @Published var shortcut: String { didSet { changed("globalShortcut", shortcut) } }
    @Published var loginEnabled = false
    @Published var loginMessage = ""
    init(defaults: UserDefaults = .standard, resolveLoginStatus: Bool = true, persistChanges: Bool = true) {
        self.defaults = defaults
        self.persistChanges = persistChanges
        defaults.register(defaults: ["notifyCompletion": true, "notifyAttention": true, "notificationSound": false,
            "notificationPreview": true, "suppressCurrent": true, "showExited": false, "statusIndicator": true,
            "globalShortcut": "option-command-p", "statusIcon": StatusIconStyle.official.rawValue])
        completion = defaults.bool(forKey: "notifyCompletion"); attention = defaults.bool(forKey: "notifyAttention")
        sound = defaults.bool(forKey: "notificationSound"); preview = defaults.bool(forKey: "notificationPreview")
        suppressCurrent = defaults.bool(forKey: "suppressCurrent"); showExited = defaults.bool(forKey: "showExited")
        indicator = defaults.bool(forKey: "statusIndicator"); shortcut = defaults.string(forKey: "globalShortcut") ?? "off"
        iconStyle = StatusIconStyle(rawValue: defaults.string(forKey: "statusIcon") ?? "") ?? .official
        if resolveLoginStatus { loginEnabled = SMAppService.mainApp.status == .enabled }
    }
    private func changed(_ key: String, _ value: Any) { if persistChanges { defaults.set(value, forKey: key) }; onChange?() }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginMessage = SMAppService.mainApp.status == .requiresApproval ? "Approve Pi Sessions in System Settings → Login Items." : ""
        } catch { loginMessage = error.localizedDescription }
    }
}

struct PanelMemory: Codable {
    static let seenEventLimit = 2000
    var pins: Set<String> = []
    var readSettlements: [String: String] = [:]
    var seenEvents: [String] = []
    var removedLinks: [String: Set<String>] = [:]
    var linkUses: [String: Int] = [:]
    var hiddenExited: Set<String> = []
    static let url = supportDirectory.appendingPathComponent("panel-state.json")
    static func load() -> PanelMemory { (try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url))) ?? Self() }
    mutating func remember(_ id: String) {
        seenEvents.append(id)
        if seenEvents.count > Self.seenEventLimit { seenEvents.removeFirst(seenEvents.count - Self.seenEventLimit) }
    }
    func isUnread(_ session: Session) -> Bool {
        guard session.exitedAt == nil, session.status == "idle", let settled = session.lastSettled, settled.outcome != "aborted" else { return false }
        return readSettlements[session.sessionId] != settled.id
    }
}

func safeLocalURL(_ value: String) -> URL? {
    guard value.count <= 4096, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
          let parts = URLComponents(string: value), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
          parts.user == nil, parts.password == nil, let port = parts.port, (1...65535).contains(port),
          let rawHost = parts.host?.lowercased() else { return nil }
    let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let octets = host.split(separator: ".", omittingEmptySubsequences: false)
    let loopback = octets.count == 4 && octets.first == "127" && octets.allSatisfy { part in
        !part.isEmpty && part.allSatisfy(\.isNumber) && Int(part).map { (0...255).contains($0) } == true
    }
    guard host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || loopback || host.hasSuffix(".local") else { return nil }
    let path = parts.path.lowercased()
    guard !["/api", "/graphql", "/health"].contains(where: { path == $0 || path.hasPrefix($0 + "/") }), !path.hasSuffix(".json") else { return nil }
    return parts.url
}

func archiveSnapshot(_ session: Session, at time: Double = Date().timeIntervalSince1970 * 1000) throws {
    guard UUID(uuidString: session.runtimeId) != nil else { return }
    var snapshot = session
    snapshot.exitedAt = snapshot.exitedAt ?? time
    try savePrivate(snapshot, to: exitedDirectory.appendingPathComponent("\(session.runtimeId).json"))
}

func loadExited(at directory: URL = exitedDirectory, now: Double = Date().timeIntervalSince1970 * 1000) -> [Session] {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    let cutoff = now - 7 * 86400000
    var result: [Session] = []
    for file in files where file.pathExtension == "json" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
        guard let session = try? readSession(file, archived: true), let at = session.exitedAt else { continue }
        if at < cutoff { try? FileManager.default.removeItem(at: file) } else { result.append(session) }
    }
    result.sort { ($0.exitedAt ?? 0) > ($1.exitedAt ?? 0) }
    for session in result.dropFirst(100) { try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(session.runtimeId).json")) }
    let snapshots = Array(result.prefix(100))
    pruneSessionCache(in: directory, keeping: snapshots.map { "\($0.runtimeId).json" })
    return snapshots
}

func cleanStaleStates() throws -> Int {
    var removed = 0
    for url in try FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) {
        guard let session = try? readSession(url), !processIsCurrent(session),
              let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              Date().timeIntervalSince(date) > 60 else { continue }
        try archiveSnapshot(session, at: date.timeIntervalSince1970 * 1000)
        if let again = try? readSession(url), again.runtimeId == session.runtimeId, !processIsCurrent(again) {
            try FileManager.default.removeItem(at: url); removed += 1
        }
    }
    return removed
}
