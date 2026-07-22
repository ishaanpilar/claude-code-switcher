import SwiftUI

/// The full Settings window (opened via "Settings…" in the panel, or Cmd-,). Built as a native
/// macOS sidebar window — `NavigationSplitView` with a selectable list on the left and a grouped
/// `Form` per pane on the right, the same shape System Settings / Xcode preferences use. The
/// menu-bar dropdown stays the quick see-and-switch surface; deep configuration lives here.
///
/// The sidebar's main sections sit in a `List`; **About** is pinned to the very bottom (a divider
/// + its own row) rather than being another list item, so it reads as app-info rather than
/// another setting — the same placement System Settings uses for its bottom items.
struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var pool: PoolState
    @ObservedObject var router: SettingsRouter

    enum Pane: String, CaseIterable, Identifiable {
        case accounts = "My Accounts"
        case teamUsage = "Team usage"
        case autoSwitch = "Auto-switch"
        case team = "Team"
        case general = "General"
        case about = "About"

        var id: String { rawValue }
        /// The configuration panes — About is handled separately (pinned to the bottom).
        static var mainCases: [Pane] { [.accounts, .teamUsage, .autoSwitch, .team, .general] }
        var icon: String {
            switch self {
            case .accounts: return "person.crop.circle"
            case .teamUsage: return "chart.bar.xaxis"
            case .autoSwitch: return "bolt"
            case .team: return "person.3"
            case .general: return "gearshape"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: Binding(get: { router.pane }, set: { router.pane = $0 ?? router.pane })) {
                    ForEach(Pane.mainCases) { p in
                        Label(p.rawValue, systemImage: p.icon).tag(p)
                    }
                }

                Spacer(minLength: 0)
                Divider()
                Button { router.pane = .about } label: {
                    HStack(spacing: 8) {
                        Image(systemName: Pane.about.icon).frame(width: 18)
                        Text("About").font(.body)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(router.pane == .about ? Color.accentColor.opacity(0.18) : .clear)
                    )
                }
                .buttonStyle(.plain)
                .padding(8)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                switch router.pane {
                case .accounts: MyAccountsPane(state: state)
                case .teamUsage: TeamUsagePane(state: state, pool: pool)
                case .autoSwitch: AutoSwitchPane(state: state)
                case .team: TeamPane(state: state, pool: pool)
                case .general: GeneralPane(state: state)
                case .about: AboutPane()
                }
            }
            .navigationTitle(router.pane.rawValue)
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 480, idealHeight: 540)
    }
}

// MARK: - My Accounts

private struct MyAccountsPane: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                Text("Each account is controlled by whoever added it. You have full control over the accounts you own; teammates' accounts are read-only here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if state.displayAccounts.isEmpty {
                Section {
                    Text("No accounts yet. Add one from the menu-bar panel.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(state.displayAccounts) { account in
                    Section {
                        AccountPaneSection(state: state, account: account, otherMembers: otherMembers)
                    } header: {
                        HStack {
                            Text(account.email)
                            if account.accountUuid == state.activeAccount?.accountUuid {
                                Text("ACTIVE").font(.caption2).foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var otherMembers: [Member] {
        state.membersById.values
            .filter { $0.userId != state.myUserId }
            .sorted { $0.displayName < $1.displayName }
    }
}

private struct AccountPaneSection: View {
    @ObservedObject var state: AppState
    let account: DisplayAccount
    let otherMembers: [Member]
    @State private var confirmRemove = false

    private var isOwner: Bool { state.isOwner(of: account) }
    private var ownerName: String? {
        guard let ownerId = account.poolAccount?.ownerUserId else { return nil }
        return state.membersById[ownerId]?.displayName
    }

    var body: some View {
        LabeledContent("Ownership") {
            Text(isOwner ? "You own this account" : "Owned by \(ownerName ?? "a teammate")")
                .foregroundStyle(.secondary)
        }

        if account.poolAccount == nil {
            LabeledContent("Status") {
                Text("Local only — not in the team pool").foregroundStyle(.secondary)
            }
        } else if isOwner {
            Picker("Sharing", selection: Binding(
                get: { account.poolAccount?.shareMode ?? .visibilityOnly },
                set: { mode in Task { await state.setShareMode(account, to: mode) } }
            )) {
                Text("Shared — teammates can switch to it").tag(ShareMode.shared)
                Text("Visibility-only — login stays on my Mac").tag(ShareMode.visibilityOnly)
            }
            .pickerStyle(.menu)

            if !otherMembers.isEmpty {
                Menu("Transfer ownership…") {
                    ForEach(otherMembers) { member in
                        Button(member.displayName) {
                            Task { await state.transferOwnership(account, to: member.userId) }
                        }
                    }
                }
            }

            Button("Remove from pool", role: .destructive) { confirmRemove = true }
                .confirmationDialog("Remove \(account.email) from the team pool?", isPresented: $confirmRemove, titleVisibility: .visible) {
                    Button("Remove from pool", role: .destructive) {
                        Task { await state.removeFromPool(account) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Teammates will no longer see or switch to it. This does not log the account out.")
                }
        } else {
            LabeledContent("Sharing") {
                Text(account.poolAccount?.shareMode == .shared ? "Shared" : "Visibility-only")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Auto-switch

private struct AutoSwitchPane: View {
    @ObservedObject var state: AppState
    private var settings: AutoSwitchSettings { state.autoSwitchSettings }

    var body: some View {
        Form {
            Section {
                Toggle("Automatically switch accounts", isOn: Binding(
                    get: { settings.enabled },
                    set: { new in update { $0.enabled = new } }
                ))
            } footer: {
                Text("When your active account crosses the threshold, move to whichever eligible account has the most room — never one a teammate is actively using.")
            }

            Section {
                Picker("Switch when usage passes", selection: Binding(
                    get: { Int(settings.threshold) },
                    set: { new in update { $0.threshold = Double(new) } }
                )) {
                    ForEach([80, 90, 95, 98], id: \.self) { Text("\($0)%").tag($0) }
                }

                Stepper("Anti-flip-flop margin: \(Int(settings.hysteresisPct))%", value: Binding(
                    get: { Int(settings.hysteresisPct) },
                    set: { new in update { $0.hysteresisPct = Double(new) } }
                ), in: 0...30, step: 5)

                Stepper("Cooldown between switches: \(Int(settings.cooldownSeconds / 60)) min", value: Binding(
                    get: { Int(settings.cooldownSeconds / 60) },
                    set: { new in update { $0.cooldownSeconds = TimeInterval(new * 60) } }
                ), in: 1...30, step: 1)

                Stepper("Check interval: \(Int(settings.intervalSeconds)) sec", value: Binding(
                    get: { Int(settings.intervalSeconds) },
                    set: { new in update { $0.intervalSeconds = TimeInterval(new) } }
                ), in: 30...300, step: 30)
            } header: {
                Text("Rules")
            } footer: {
                Text("Defaults (90% / 10% / 5 min / 60 sec) are tuned against the usage API's real rate-limit shape — change them only if you know why.")
            }
            .disabled(!settings.enabled)
        }
        .formStyle(.grouped)
    }

    private func update(_ mutate: (inout AutoSwitchSettings) -> Void) {
        var copy = state.autoSwitchSettings
        mutate(&copy)
        state.updateAutoSwitchSettings(copy)
    }
}

// MARK: - Team

private struct TeamPane: View {
    @ObservedObject var state: AppState
    @ObservedObject var pool: PoolState
    @State private var inviteCode: String?
    @State private var isGenerating = false
    @State private var confirmLeave = false
    @State private var showAddTeam = false
    @State private var addMode: AddMode = .create
    @State private var newTeamName = ""
    @State private var joinCode = ""
    @State private var joinKey = ""

    enum AddMode: String, CaseIterable, Identifiable { case create = "Create", join = "Join"; var id: String { rawValue } }

    var body: some View {
        Form {
            if pool.isLocalOnlyMode {
                localOnlySection
            } else if case .ready(let team, let member) = pool.step {
                if pool.availableTeams.count > 1 {
                    Section {
                        Picker("Active team", selection: Binding(
                            get: { pool.activeTeamId ?? team.id },
                            set: { pool.switchActiveTeam(to: $0) }
                        )) {
                            ForEach(pool.availableTeams) { t in Text(t.name).tag(t.id) }
                        }
                    } footer: {
                        Text("Switching changes which pool the app shares and switches accounts within. Your teams never see each other.")
                    }
                }

                Section {
                    LabeledContent("Team", value: team.name)
                    LabeledContent("Your role", value: member.role == "owner" ? "Owner" : "Member")
                }

                Section {
                    Toggle("Reserve my accounts while I'm using them", isOn: Binding(
                        get: { state.reserveAccountsWhileInUse },
                        set: { state.setReserveAccountsWhileInUse($0) }
                    ))
                } footer: {
                    Text("Off by default — teammates can use the same account at the same time. Turn on to reserve accounts you own while you're using them (shows a \"held by you\" badge, blocks others, and steers auto-switch away). This only ever reserves accounts you own — never a teammate's.")
                }

                Section("Members") {
                    ForEach(state.membersById.values.sorted { $0.displayName < $1.displayName }) { m in
                        LabeledContent {
                            Text(m.role).foregroundStyle(.secondary)
                        } label: {
                            HStack {
                                Text(m.displayName)
                                if m.userId == state.myUserId {
                                    Text("you").font(.caption2).foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }

                if member.role == "owner" {
                    Section {
                        Button(isGenerating ? "Generating…" : "Generate invite code") {
                            isGenerating = true
                            Task { inviteCode = await pool.createInvite(); isGenerating = false }
                        }
                        .disabled(isGenerating)

                        if !isGenerating, let error = pool.lastError {
                            Text(error).foregroundStyle(.red)
                        }

                        if let inviteCode {
                            LabeledContent("Invite code") {
                                HStack {
                                    Text(inviteCode).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                    Button { copy(inviteCode) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                                }
                            }
                        }
                        if let key = pool.currentTeamKeyForSharing(team: team) {
                            LabeledContent("Team key") {
                                HStack {
                                    Text(key).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                    Button { copy(key) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                                }
                            }
                        }
                    } header: {
                        Text("Invite a teammate")
                    } footer: {
                        Text("Send both the code and the team key, out-of-band. Single-use, expires in 7 days.")
                    }
                }

                addAnotherTeamSection

                Section {
                    Button("Sign out") { Task { await pool.signOut() } }
                    Button("Leave team", role: .destructive) { confirmLeave = true }
                        .confirmationDialog("Leave this team?", isPresented: $confirmLeave, titleVisibility: .visible) {
                            Button("Leave team", role: .destructive) { Task { await pool.leaveTeam() } }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Your accounts are removed from the pool. If you're the owner, you must first transfer team ownership or remove the other members.")
                        }
                }
            } else {
                Section { Text("Not on a team yet.").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    /// Create or join an *additional* team from Settings (the multi-team story: a separate pool
    /// with a different set of people). Same RPCs as first-time onboarding; joining a team
    /// switches to it automatically.
    private var addAnotherTeamSection: some View {
        Section {
            if !showAddTeam {
                Button("Create or join another team…") { showAddTeam = true }
            } else {
                Picker("", selection: $addMode) {
                    ForEach(AddMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if addMode == .create {
                    TextField("New team name", text: $newTeamName)
                    Button("Create team") {
                        Task { await pool.createTeam(name: newTeamName); reset() }
                    }
                    .disabled(newTeamName.isEmpty || pool.isBusy)
                } else {
                    TextField("Invite code", text: $joinCode)
                    TextField("Team key", text: $joinKey)
                    Button("Join team") {
                        Task { await pool.joinTeam(code: joinCode, teamKeyString: joinKey); reset() }
                    }
                    .disabled(joinCode.isEmpty || joinKey.isEmpty || pool.isBusy)
                }
                Button("Cancel", role: .cancel) { reset() }
            }
        } header: {
            Text("Another team")
        }
    }

    private var localOnlySection: some View {
        Section {
            Text("You're in offline mode — the app switches between just this Mac's own accounts, with no cloud and no sharing.")
                .foregroundStyle(.secondary)
            Button("Sign in to use a team") { pool.exitLocalOnly() }
        } header: {
            Text("Offline mode")
        }
    }

    private func reset() {
        showAddTeam = false
        newTeamName = ""; joinCode = ""; joinKey = ""
        addMode = .create
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { state.launchAtLoginEnabled },
                    set: { state.setLaunchAtLogin($0) }
                ))
                Toggle("Show notifications for auto-switch events", isOn: Binding(
                    get: { state.notificationsEnabled },
                    set: { state.setNotificationsEnabled($0) }
                ))
            }

            Section {
                Toggle("Log my prompts for attribution", isOn: Binding(
                    get: { state.attributionEnabled },
                    set: { state.setAttributionEnabled($0) }
                ))
            } footer: {
                Text("Installs a Claude Code hook that records a timestamp and the active account on every prompt you submit — never prompt contents. Powers the Team-usage digest.")
            }

            Section {
                Text("Sharing one subscription across several people and IPs cuts against Anthropic's consumer terms and can look anomalous to their systems. This app does nothing to hide or evade that.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Heads up")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutPane: View {
    private static let developerName = "Ishaan Pilar"
    private static let developerEmail = "ishaanpilar98@gmail.com"
    private static let repoURL = "https://github.com/ishaanpilar/claude-code-switcher"

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    /// The logo the build script copies into the bundle. Falls back to the live app icon when
    /// running as a bare dev binary (where Bundle.main isn't the .app and has no logo.png).
    private var logo: NSImage {
        if let url = Bundle.main.url(forResource: "logo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApplication.shared.applicationIconImage ?? NSImage()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 128, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)

                VStack(spacing: 3) {
                    Text("Claude Code Switcher").font(.title2).fontWeight(.semibold)
                    Text(version).font(.callout).foregroundStyle(.secondary)
                    Text("Made by \(Self.developerName)").font(.callout).foregroundStyle(.secondary)
                }

                Divider().padding(.vertical, 4)

                VStack(spacing: 8) {
                    linkButton("Email the developer", systemImage: "envelope") {
                        openMail(subject: "Claude Code Switcher")
                    }
                    linkButton("Report a bug", systemImage: "ladybug") {
                        openMail(subject: "Claude Code Switcher — Bug report",
                                 body: "Describe what happened:\n\n\n---\n\(version)\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                    }
                    linkButton("View source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right") {
                        if let url = URL(string: Self.repoURL) { NSWorkspace.shared.open(url) }
                    }
                    linkButton("Reveal logs in Finder", systemImage: "doc.text.magnifyingglass") {
                        Diagnostics.revealLogsInFinder()
                    }
                }
                .frame(maxWidth: 320)

                Spacer(minLength: 0)

                Text("© 2026 \(Self.developerName). Logs record app events only — never tokens or prompt contents.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(28)
        }
    }

    private func linkButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openMail(subject: String, body: String? = nil) {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Self.developerEmail
        var items = [URLQueryItem(name: "subject", value: subject)]
        if let body { items.append(URLQueryItem(name: "body", value: body)) }
        components.queryItems = items
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
