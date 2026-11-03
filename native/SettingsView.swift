import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var preferences: Preferences
    let onBack: () -> Void
    private func iconOption(_ style: StatusIconStyle) -> some View {
        let selected = preferences.iconStyle == style
        return Button { preferences.iconStyle = style } label: {
            VStack(spacing: 5) {
                StatusIconPreview(style: style).frame(width: 28, height: 28).accessibilityHidden(true)
                Text(style.title).font(.caption).multilineTextAlignment(.center).lineLimit(2).frame(height: 28)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(selected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
            .overlay(alignment: .topTrailing) {
                if selected { Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(Color.accentColor).padding(5).accessibilityHidden(true) }
            }
        }.buttonStyle(.plain).help("Use \(style.title) icon")
            .accessibilityLabel(style.title).accessibilityValue(selected ? "Selected" : "Not selected")
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: onBack) { Label("Back", systemImage: "chevron.left") }.buttonStyle(.borderless)
                Spacer(); Text("Settings").font(.headline); Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Appearance") {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Pi icon style").font(.subheadline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                                ForEach(StatusIconStyle.allCases) { style in
                                    iconOption(style)
                                }
                            }
                            Text("Updates the menu bar and panel title immediately.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    GroupBox("Notifications") {
                        VStack(alignment: .leading, spacing: 9) {
                            Toggle("When a run completes or fails", isOn: $preferences.completion)
                            Toggle("When input or confirmation is needed", isOn: $preferences.attention)
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle("Repeat while attention is needed", isOn: $preferences.repeatAttention)
                                HStack {
                                    Text("Remind every")
                                    TextField("Minutes", value: $preferences.attentionReminderMinutes, format: .number.grouping(.never))
                                        .frame(width: 56).textFieldStyle(.roundedBorder)
                                        .accessibilityLabel("Attention reminder interval in minutes")
                                    Text("minutes")
                                    Stepper("Reminder interval", value: $preferences.attentionReminderMinutes, in: 1...1440)
                                        .labelsHidden()
                                }.disabled(!preferences.repeatAttention)
                                Text("1–1440 minutes. Stops when the session no longer needs attention. Requires Pi Sessions to be running.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.leading, 18).disabled(!preferences.attention)
                            Toggle("Play a sound", isOn: $preferences.sound)
                            Toggle("Include reply / prompt previews", isOn: $preferences.preview)
                            Toggle("Silence the session I'm viewing", isOn: $preferences.suppressCurrent)
                            if let notifications = store.notifications { NotificationPermissionView(notifications: notifications) }
                            HStack {
                                Button("Enable / Check Permission") { store.notifications?.requestPermission() }
                                Button("Send Test") { store.testNotification() }
                            }
                            Text("Click a notification to jump to its session. macOS Focus and notification style settings control banner visibility.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    GroupBox("Panel") {
                        VStack(alignment: .leading, spacing: 9) {
                            Toggle("Show recently exited sessions", isOn: $preferences.showExited)
                            Toggle("Show a dot for unread / pending sessions", isOn: $preferences.indicator)
                            Picker("Global shortcut", selection: $preferences.shortcut) {
                                Text("⌥⌘P").tag("option-command-p")
                                Text("⌃⌥P").tag("control-option-p")
                                Text("⌃⌥Space").tag("control-option-space")
                                Text("Off").tag("off")
                            }
                            Toggle("Launch at login", isOn: Binding(get: { preferences.loginEnabled }, set: { preferences.setLogin($0) }))
                            if !preferences.loginMessage.isEmpty { Text(preferences.loginMessage).font(.caption).foregroundStyle(.orange) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    GroupBox("Local data") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("History: 7 days, up to 100 sessions. State and summaries stay on this Mac. Local links open only when clicked.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Clean Stale Files") { store.cleanup() }
                                Button("Clear Exited History") { for session in store.sessions where session.exitedAt != nil { store.removeExited(session) } }
                            }
                            Button("Open Data Folder") { NSWorkspace.shared.open(supportDirectory) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    if let message = store.notice { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let error = store.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
        }.padding(16)
        .onAppear { preferences.loginEnabled = SMAppService.mainApp.status == .enabled; store.notifications?.refreshPermission() }
        .onChange(of: preferences.completion) { if $0 { store.notifications?.requestPermission() } }
        .onChange(of: preferences.attention) { if $0 { store.notifications?.requestPermission() } }
    }
}

private struct NotificationPermissionView: View {
    @ObservedObject var notifications: SessionNotifications
    var body: some View {
        HStack {
            Text("Permission: \(notifications.permission)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            }.font(.caption)
        }
    }
}
