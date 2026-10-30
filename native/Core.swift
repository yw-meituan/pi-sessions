import Foundation
import Darwin

let sessionsDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/PiSessionPanel/sessions", isDirectory: true)

struct PanelError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Session: Codable, Equatable, Identifiable {
    struct Tmux: Codable, Equatable { let socket: String; let pane: String }
    let version: Int
    let pid: Int32
    let processStart: String
    let runtimeId: String
    let sessionId: String
    let cwd: String
    let changedAt: Double
    let task: String?
    let name: String?
    let model: String?
    let status: String
    let activity: String
    let tty: String?
    let tmux: Tmux?
    struct Settlement: Codable, Equatable { let id: String; let at: Double; let outcome: String }
    struct Attention: Codable, Equatable { let id: String; let at: Double; let title: String }
    var sessionFile: String? = nil
    var lastReply: String? = nil
    var links: [String]? = nil
    var lastSettled: Settlement? = nil
    var attention: Attention? = nil
    var runStartedAt: Double? = nil
    var exitedAt: Double? = nil
    var effectiveStatus: String { exitedAt == nil ? status : "exited" }
    var locationLabel: String { tmux.map { "tmux \($0.pane) · iTerm2" } ?? "iTerm2" }

    var id: String { runtimeId }
    var project: String { URL(fileURLWithPath: cwd).lastPathComponent }
    var title: String {
        if let name, !name.isEmpty { return name }
        if let task, !task.isEmpty { return task }
        return sessionId.isEmpty ? "Session" : String(sessionId.prefix(8))
    }
    private static let legacyActivities = ["等待输入": "Ready for input", "运行中": "Running", "等待确认": "Awaiting confirmation",
        "运行出错": "Failed", "已完成": "Completed", "已中止": "Stopped", "压缩上下文": "Compacting context"]
    var statusPriority: Int {
        if exitedAt != nil { return 3 }
        switch status { case "attention": return 0; case "busy": return 1; case "idle": return 2; default: return 3 }
    }
    // Older running producers may still publish the original activity labels.
    var displayActivity: String {
        if exitedAt != nil { return "Exited" }
        if let translated = Self.legacyActivities[activity] { return translated }
        if activity.hasPrefix("执行 ") { return "Running " + activity.dropFirst(3) }
        return activity
    }
    var isValid: Bool {
        version == 1 && pid > 0 && UUID(uuidString: runtimeId) != nil &&
        ["attention", "busy", "idle"].contains(status) && changedAt.isFinite && !processStart.isEmpty
    }
}

enum SessionTab: String, CaseIterable {
    case all, attention, busy, idle, exited
    var title: String {
        switch self { case .all: return "All"; case .attention: return "Attention"; case .busy: return "Running"; case .idle: return "Idle"; case .exited: return "Exited" }
    }
    func includes(_ session: Session) -> Bool {
        if self == .all { return true }
        if session.exitedAt != nil { return self == .exited }
        return session.status == rawValue
    }
}

func filteredSessions(_ sessions: [Session], tab: SessionTab, query: String) -> [Session] {
    let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
    let matches = sessions.filter { session in
        guard tab.includes(session) else { return false }
        guard !words.isEmpty else { return true }
        let searchable = [session.cwd, session.title, session.displayActivity, session.model ?? "", session.sessionId, session.lastReply ?? ""]
            .joined(separator: " ") as NSString
        return words.allSatisfy { searchable.localizedCaseInsensitiveContains($0) }
    }
    let ordered = matches.enumerated().map {
        (index: $0.offset, rank: $0.element.statusPriority, time: $0.element.changedAt, id: $0.element.id)
    }.sorted {
        if $0.rank != $1.rank { return $0.rank < $1.rank }
        if $0.time != $1.time { return $0.time > $1.time }
        return $0.id < $1.id
    }
    return ordered.map { matches[$0.index] }
}

private enum ProcessStartDate {
    static var dates: [String: Date] = [:]
    static let lock = NSLock()
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()
    static func parse(_ value: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        let zone = TimeZone.current
        if formatter.timeZone != zone {
            formatter.timeZone = zone
            dates.removeAll(keepingCapacity: true)
        }
        if let date = dates[value] { return date }
        guard let date = formatter.date(from: value) else { return nil }
        if value.utf8.count <= 64 {
            if dates.count >= 512 { dates.removeAll(keepingCapacity: true) }
            dates[value] = date
        }
        return date
    }
}

private enum ProcessStatus {
    case alive(Double), gone, unavailable
}

private func inspectProcess(_ pid: Int32) -> ProcessStatus {
    var info = proc_bsdinfo()
    errno = 0
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else {
        return errno == ESRCH ? .gone : .unavailable
    }
    return info.pbi_status == SZOMB ? .gone : .alive(Double(info.pbi_start_tvsec))
}

func processIsCurrent(_ session: Session) -> Bool {
    guard session.isValid, case let .alive(start) = inspectProcess(session.pid) else { return false }
    let normalized = session.processStart.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard let date = ProcessStartDate.parse(normalized) else { return false }
    return abs(date.timeIntervalSince1970 - start) < 1
}

private enum DecodedSessions {
    struct Entry { let data: Data; let session: Session; let archived: Bool }
    static let lock = NSLock()
    static var entries: [String: Entry] = [:]
    static var byteCount = 0
    static func lookup(_ path: String, data: Data, archived: Bool) -> Session? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[path] else { return nil }
        if entry.archived == archived && entry.data == data { return entry.session }
        byteCount -= entry.data.count
        entries.removeValue(forKey: path)
        return nil
    }
    static func remove(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        if let old = entries.removeValue(forKey: path) { byteCount -= old.data.count }
    }
    static func prune(directory: String, keeping paths: Set<String>) {
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        lock.lock(); defer { lock.unlock() }
        for path in entries.keys where path.hasPrefix(prefix) && !paths.contains(path) && !path.dropFirst(prefix.count).contains("/") {
            if let old = entries.removeValue(forKey: path) { byteCount -= old.data.count }
        }
    }
    static func store(_ session: Session, data: Data, path: String, archived: Bool) {
        guard data.count < 131072 else { return }
        lock.lock(); defer { lock.unlock() }
        if let old = entries.removeValue(forKey: path) { byteCount -= old.data.count }
        if entries.count >= 128 || byteCount + data.count > 524288 {
            entries.removeAll(keepingCapacity: true); byteCount = 0
        }
        entries[path] = Entry(data: data, session: session, archived: archived)
        byteCount += data.count
    }
}

func readSession(_ url: URL, archived: Bool = false) throws -> Session {
    let path = url.path
    do {
        var attributes = stat()
        guard lstat(path, &attributes) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard attributes.st_size < 131072 else { throw PanelError("State file is too large") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.readToEnd() ?? Data()
        if let session = DecodedSessions.lookup(path, data: data, archived: archived) { return session }
        let session = try JSONDecoder().decode(Session.self, from: data)
        let expectedName = archived ? "\(session.runtimeId).json" : "\(session.pid).json"
        guard session.isValid, url.lastPathComponent == expectedName, !archived || session.exitedAt != nil else { throw PanelError("Invalid session state") }
        DecodedSessions.store(session, data: data, path: path, archived: archived)
        return session
    } catch {
        DecodedSessions.remove(path)
        throw error
    }
}

func pruneSessionCache(in directory: URL, keeping names: [String]) {
    let path = directory.path
    let prefix = path.hasSuffix("/") ? path : path + "/"
    DecodedSessions.prune(directory: path, keeping: Set(names.map { prefix + $0 }))
}

func scanSessions(at directory: URL = sessionsDirectory) throws -> [Session] {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    var livePaths: Set<String> = []
    let sessions: [Session] = names.compactMap { name in
        guard name.hasSuffix(".json"), let pid = Int32(name.dropLast(5)), pid > 0 else { return nil }
        if case .gone = inspectProcess(pid) { return nil }
        let url = directory.appendingPathComponent(name, isDirectory: false)
        guard let session = try? readSession(url), processIsCurrent(session) else { return nil }
        livePaths.insert(url.path)
        return session
    }
    DecodedSessions.prune(directory: directory.path, keeping: livePaths)
    return filteredSessions(sessions, tab: .all, query: "")
}

private final class ProcessOutput: @unchecked Sendable { var data = Data() }

func runProcess(_ path: String, _ arguments: [String], timeout: TimeInterval = 4) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "C"
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let exited = DispatchSemaphore(value: 0)
    let drained = DispatchSemaphore(value: 0)
    let output = ProcessOutput()
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    DispatchQueue.global(qos: .utility).async {
        output.data = pipe.fileHandleForReading.readDataToEndOfFile()
        drained.signal()
    }
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        if exited.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        throw PanelError("Command timed out: \(URL(fileURLWithPath: path).lastPathComponent)")
    }
    guard drained.wait(timeout: .now() + 2) == .success else { throw PanelError("Timed out reading command output") }
    let result = String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else { throw PanelError(result.isEmpty ? "Command failed: \(path)" : result) }
    return result
}

struct TmuxClient: Equatable {
    let tty: String
    let session: String
    let activity: Double
}

func chooseClient(_ clients: [TmuxClient], session: String, terminalTTYs: [String]) -> TmuxClient? {
    clients.filter { terminalTTYs.contains($0.tty) }.sorted {
        if ($0.session == session) != ($1.session == session) { return $0.session == session }
        return $0.activity > $1.activity
    }.first
}
