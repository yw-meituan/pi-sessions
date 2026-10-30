import Foundation
import AppKit
import Carbon

struct FocusPlan: Equatable {
    let socket: String?
    let commands: [String]
    let terminalTTY: String
}

func hasID(_ value: String, prefix: Character) -> Bool {
    value.first == prefix && value.count > 1 && value.dropFirst().allSatisfy(\.isNumber)
}

func makeFocusPlan(socket: String, pane: String, location: [String], clients: [TmuxClient], terminalTTYs: [String]) throws -> FocusPlan {
    guard location.count == 4, hasID(location[0], prefix: "$"), hasID(location[1], prefix: "@"),
          hasID(pane, prefix: "%"), location[2] == pane else { throw PanelError("The tmux pane no longer exists") }
    let session = location[0], window = location[1]
    guard let client = chooseClient(clients, session: session, terminalTTYs: terminalTTYs) else {
        throw PanelError("No available iTerm2 tmux client. Attach tmux in iTerm2 first.")
    }
    var commands = ["select-window", "-t", "\(session):\(window)", ";", "select-pane", "-t", pane]
    if location[3] == "1" { commands += [";", "resize-pane", "-Z", "-t", pane] }
    if client.session != session { commands += [";", "switch-client", "-c", client.tty, "-t", session] }
    return FocusPlan(socket: socket, commands: commands, terminalTTY: client.tty)
}

struct TerminalFocus {
    func visibleSessionID(_ sessions: [Session]) -> String? {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.googlecode.iterm2")
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").isEmpty,
              let descriptor = target.aeDesc,
              AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, false) == noErr,
              let script = Bundle.main.url(forResource: "iterm", withExtension: "applescript"),
              let tty = try? runProcess("/usr/bin/osascript", [script.path, "current"], timeout: 3), !tty.isEmpty else { return nil }
        for session in sessions where session.exitedAt == nil {
            if let location = session.tmux {
                let clients = (try? tmux(location.socket, ["list-clients", "-F", "#{client_tty}\t#{session_id}"])) ?? ""
                let target = clients.split(separator: "\n").map { $0.components(separatedBy: "\t") }
                    .first { $0.count == 2 && $0[0] == tty }?[1]
                if let target, hasID(target, prefix: "$"),
                   (try? tmux(location.socket, ["display-message", "-p", "-t", target, "#{pane_id}"])) == location.pane {
                    return session.runtimeId
                }
            } else if session.tty == tty { return session.runtimeId }
        }
        return nil
    }
    var tmuxExecutable: String {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/tmux"
    }
    func tmux(_ socket: String, _ args: [String]) throws -> String {
        try runProcess(tmuxExecutable, ["-S", socket] + args)
    }
    func iterm(_ args: [String]) throws -> String {
        guard let script = Bundle.main.url(forResource: "iterm", withExtension: "applescript") else {
            throw PanelError("The iTerm2 focus script is missing. Reinstall Pi Sessions.")
        }
        do { return try runProcess("/usr/bin/osascript", [script.path] + args, timeout: 120) }
        catch {
            if error.localizedDescription.contains("-1743") {
                throw PanelError("Allow Pi Sessions to control iTerm2 in System Settings → Privacy & Security → Automation.")
            }
            throw error
        }
    }
    func current(_ selected: Session) throws -> Session {
        guard selected.exitedAt == nil else { throw PanelError("This session has exited. Use Copy Resume Command to reopen it.") }
        let session = try readSession(sessionsDirectory.appendingPathComponent("\(selected.pid).json"))
        guard session.runtimeId == selected.runtimeId, processIsCurrent(session) else {
            throw PanelError("This session has exited or changed. Refresh the list.")
        }
        return session
    }
    func plan(_ selected: Session) throws -> FocusPlan {
        let session = try current(selected)
        guard let location = session.tmux else {
            guard let tty = session.tty, !tty.isEmpty else { throw PanelError("This session has no terminal to focus") }
            return FocusPlan(socket: nil, commands: [], terminalTTY: tty)
        }
        guard location.socket.hasPrefix("/"), hasID(location.pane, prefix: "%") else { throw PanelError("Invalid tmux location") }
        let paneInfo = try tmux(location.socket, ["display-message", "-p", "-t", location.pane,
            "#{session_id}\t#{window_id}\t#{pane_id}\t#{window_zoomed_flag}"]).components(separatedBy: "\t")
        let clients = try tmux(location.socket, ["list-clients", "-F", "#{client_tty}\t#{session_id}\t#{client_activity}"])
            .split(separator: "\n").compactMap { line -> TmuxClient? in
                let parts = line.split(separator: "\t").map(String.init)
                guard parts.count == 3 else { return nil }
                return TmuxClient(tty: parts[0], session: parts[1], activity: Double(parts[2]) ?? 0)
            }
        let terminals = try iterm(["list"]).components(separatedBy: "\n")
        return try makeFocusPlan(socket: location.socket, pane: location.pane, location: paneInfo, clients: clients, terminalTTYs: terminals)
    }
    func focus(_ selected: Session) throws {
        let target = try plan(selected)
        // Permission dialogs can take time; reject a replaced session before switching.
        _ = try current(selected)
        if let socket = target.socket { _ = try tmux(socket, target.commands) }
        _ = try iterm(["focus", target.terminalTTY])
    }
}
