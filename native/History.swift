import Foundation

// Confined to SessionStore's serial scan queue.
final class SessionHistoryReader {
    let directory: URL
    private var cached: [Session]?
    init(directory: URL = exitedDirectory) { self.directory = directory }
    func invalidate() { cached = nil }
    func load(now: Double = Date().timeIntervalSince1970 * 1000) -> [Session] {
        if let cached, (cached.last?.exitedAt ?? .infinity) >= now - 7 * 86400000 { return cached }
        let snapshots = loadExited(at: directory, now: now)
        cached = snapshots
        return snapshots
    }
}
