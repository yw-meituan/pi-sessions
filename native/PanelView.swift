import SwiftUI

struct PanelView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var preferences: Preferences
    @AppStorage("selectedTab") private var selectedTab = SessionTab.all.rawValue
    @State private var query = ""
    @State private var unreadOnly = false
    @State private var settings = false
    @State private var selection = SessionKeyboardSelection()
    @FocusState private var searchFocused: Bool
    let onSelect: (Session) -> Void
    let onClose: () -> Void
    let onQuit: () -> Void
    private var tab: SessionTab { SessionTab(rawValue: selectedTab) ?? .all }
    private var rows: [Session] { store.rows(tab: tab, query: query, unreadOnly: unreadOnly) }
    private var tabs: [SessionTab] { SessionTab.allCases.filter { preferences.showExited || $0 != .exited } }
    private var selectableIDs: [String] { rows.filter { $0.exitedAt == nil }.map(\.id) }
    private var selectedID: String? { selection.resolved(in: selectableIDs) }
    private var filters: [String] { [selectedTab, String(unreadOnly), query] }

    private func openSelected() {
        guard !store.focusing, let session = rows.first(where: { $0.id == selectedID && $0.exitedAt == nil }) else { return }
        onSelect(session)
    }

    var body: some View {
        Group {
            if settings { SettingsView(store: store, preferences: preferences, onBack: { settings = false; searchFocused = true }) }
            else { panel }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onExitCommand { if settings { settings = false } else { onClose() } }
        .onChange(of: preferences.showExited) { if !$0 && tab == .exited { selectedTab = SessionTab.all.rawValue } }
        .onChange(of: filters) { _ in selection.id = nil }
        .onChange(of: selectableIDs) { ids in selection.id = selection.resolved(in: ids) }
        .onReceive(NotificationCenter.default.publisher(for: .init("PiSessionsFocusSearch"))) { _ in
            selection.id = nil
            searchFocused = !settings
        }
    }
    private var panel: some View {
        VStack(spacing: 10) {
            HStack {
                StatusIconPreview(style: preferences.iconStyle).frame(width: 26, height: 26).accessibilityHidden(true)
                Text("Pi Sessions").font(.headline)
                Button {
                    unreadOnly.toggle()
                    if unreadOnly { selectedTab = SessionTab.all.rawValue; query = "" }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: unreadOnly ? "line.3.horizontal.decrease.circle.fill" : "envelope.badge")
                        Text("\(store.unreadCount) unread")
                        if unreadOnly { Image(systemName: "xmark").font(.caption2) }
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .foregroundStyle(unreadOnly ? Color.white : Color.accentColor)
                    .background(unreadOnly ? Color.accentColor : Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain).keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(store.unreadCount == 0 && !unreadOnly)
                .help(unreadOnly ? "Show all sessions (⌘⇧U)" : "Show unread sessions (⌘⇧U)")
                .accessibilityLabel("\(store.unreadCount) unread sessions")
                .accessibilityValue(unreadOnly ? "Unread filter on" : "Unread filter off")
                Spacer()
                if store.focusing { ProgressView().controlSize(.small).help("Opening terminal") }
                Button(action: { store.error = nil; store.refresh() }) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
                Menu {
                    Button("Mark All Read") { store.markAllRead() }
                    Button("Open Data Folder") { NSWorkspace.shared.open(supportDirectory) }
                    Divider()
                    Button("Quit Pi Sessions", action: onQuit)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("More")
                Button { settings = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).keyboardShortcut(",").help("Settings (⌘,)").accessibilityLabel("Settings")
            }
            Picker("Session status", selection: Binding(get: { selectedTab }, set: { selectedTab = $0; unreadOnly = false })) {
                ForEach(tabs, id: \.rawValue) { tab in
                    Text("\(tab.title) \(store.visibleSessions.filter { tab.includes($0) }.count)").tag(tab.rawValue)
                }
            }.pickerStyle(.segmented).labelsHidden()
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search projects, sessions, or replies", text: $query).textFieldStyle(.plain)
                    .focused($searchFocused).accessibilityLabel("Search sessions")
                    .onSubmit { openSelected() }
                    .background(SearchArrowKeys(enabled: searchFocused && !settings && !store.focusing) { offset in
                        selection.move(offset, in: selectableIDs)
                    })
                if !query.isEmpty {
                    Button(action: { query = "" }) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                }
            }.padding(8).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 7))
            if let error = store.error {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button(action: { store.error = nil }) { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(9).background(Color.orange.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 7))
            }
            if rows.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "terminal").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(unreadOnly && store.unreadCount == 0 ? "All caught up" : store.sessions.isEmpty ? "No sessions yet" : "No matching sessions").font(.headline)
                    Text(unreadOnly && store.unreadCount == 0 ? "No unread completions" : store.sessions.isEmpty ? "Run /reload in an existing Pi session" : "Try another tab or search")
                        .font(.caption).foregroundStyle(.secondary)
                    if unreadOnly {
                        Button("Show all sessions") { unreadOnly = false; query = "" }
                            .buttonStyle(.borderless)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(rows) { session in
                                SessionRow(store: store, session: session, selected: session.id == selectedID) { onSelect(session) }
                                    .id(session.id)
                            }
                        }.padding(.vertical, 2)
                    }
                    .onAppear { if let selectedID { proxy.scrollTo(selectedID, anchor: .top) } }
                    .onChange(of: selectedID) { id in if let id { proxy.scrollTo(id) } }
                    .onReceive(NotificationCenter.default.publisher(for: .init("PiSessionsFocusSearch"))) { _ in
                        if let first = selectableIDs.first { proxy.scrollTo(first, anchor: .top) }
                    }
                }.id(filters).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Text(unreadOnly ? "\(rows.count) unread sessions" : "\(rows.count) / \(store.visibleSessions.count) sessions")
                Spacer()
                Text("↑↓ select · Return opens · Esc closes")
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }
}

private struct SessionRow: View {
    @ObservedObject var store: SessionStore
    let session: Session
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var expandedReply = false
    private var unread: Bool { store.memory.isUnread(session) }
    private var pinned: Bool { store.memory.pins.contains(session.sessionId) }
    private var color: Color { session.effectiveStatus == "attention" ? .orange : session.effectiveStatus == "busy" ? .blue : .secondary }
    private var symbol: String {
        switch session.effectiveStatus { case "exited": return "power"; case "attention": return "questionmark.circle.fill"; case "busy": return "circle.fill"; default: return "circle" }
    }
    private var age: String {
        let seconds = max(0, Int(store.now.timeIntervalSince1970 - (session.exitedAt ?? session.changedAt) / 1000))
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                openButton
                if unread {
                    Button { store.markRead(session) } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24, height: 24)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Mark read without opening the terminal")
                    .accessibilityLabel("Mark read: \(session.title)")
                    .accessibilityIdentifier("mark-read-\(session.id)")
                }
            }
            replyAndLinks
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        .background(unread ? Color.accentColor.opacity(0.12) : Color.clear)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(selected ? 0.12 : hovering ? 0.08 : 0)).allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            if unread { Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 9).allowsHitTesting(false) }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : unread ? Color.accentColor.opacity(0.35) : Color.clear,
                              lineWidth: selected ? 2 : 1).allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8)).onHover { hovering = $0 }
        .contextMenu {
            Button(pinned ? "Unpin" : "Pin") { store.togglePin(session) }
            Button("Mark Read") { store.markRead(session) }
            Divider()
            Button("Copy Name") { copy(session.title) }
            Button("Copy Project Path") { copy(session.cwd) }
            Button("Copy Session ID") { copy(session.sessionId) }
            if let reply = session.lastReply, !reply.isEmpty { Button("Copy Last Reply") { copy(reply) } }
            Button("Open Project in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd)) }
            if let file = session.sessionFile {
                Button("Reveal Transcript") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
                Button("Copy Resume Command") { copy("cd \(quote(session.cwd)) && pi --session \(quote(file))") }
            }
            if !(session.links ?? []).isEmpty { Divider(); Button("Remove All Links") { store.removeAllLinks(session) } }
            if session.exitedAt != nil { Divider(); Button("Remove from History") { store.removeExited(session) } }
        }
        .help("\(session.cwd)\n\(session.title)\n\(session.tmux?.pane ?? session.tty ?? "")")
    }
    private var openButton: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(color).frame(width: 15).padding(.top, 4)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(session.project).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        if pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                        if unread {
                            Text("UNREAD").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.14)).clipShape(Capsule())
                        }
                        if store.currentRuntimeID == session.runtimeId { Image(systemName: "eye").font(.caption).help("Visible in the terminal you were using") }
                        Spacer(minLength: 5)
                        Text(age).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(session.title).font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.leading)
                    HStack {
                        Text(session.displayActivity).lineLimit(1)
                        Spacer(minLength: 4)
                        if let model = session.model, !model.isEmpty { Text(model).lineLimit(1).truncationMode(.middle) }
                    }.font(.caption2).foregroundStyle(.secondary)
                    Text(session.locationLabel).font(.caption2).foregroundStyle(.tertiary)
                }
                if session.exitedAt == nil {
                    Image(systemName: selected ? "return" : "arrow.up.forward").font(.caption)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary).padding(.top, 3)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(store.focusing || session.exitedAt != nil)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    @ViewBuilder private var replyAndLinks: some View {
        if let reply = session.lastReply, !reply.isEmpty {
            HStack(alignment: .top, spacing: 5) {
                Text(reply).font(.caption).foregroundStyle(.secondary).lineLimit(expandedReply ? nil : 2).textSelection(.enabled)
                Spacer(minLength: 0)
                Button { expandedReply.toggle() } label: { Image(systemName: expandedReply ? "chevron.up" : "chevron.down") }
                    .font(.caption2).buttonStyle(.borderless).help(expandedReply ? "Collapse reply" : "Expand last reply")
            }.padding(.leading, 24)
        }
        if !store.links(for: session).isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(store.links(for: session).prefix(3)), id: \.self) { value in link(value) }
                if store.links(for: session).count > 3 {
                    Menu("+\(store.links(for: session).count - 3)") {
                        ForEach(Array(store.links(for: session).dropFirst(3)), id: \.self) { value in
                            Button(value) { store.openLink(value) }
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                Spacer(minLength: 0)
            }.padding(.leading, 24)
        }
    }
    private func link(_ value: String) -> some View {
        Button { store.openLink(value) } label: {
            Text(value.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: ""))
                .font(.caption2).lineLimit(1).truncationMode(.middle).padding(.horizontal, 5).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.borderless).help(value)
        .contextMenu {
            Button("Open") { store.openLink(value) }
            Button("Copy URL") { copy(value) }
            Button("Remove") { store.removeLink(value, from: session) }
        }
    }
}
