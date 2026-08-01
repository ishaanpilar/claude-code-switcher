import SwiftUI

/// The dropdown itself (`MenuBarExtra(..., style: .window)`'s content): header with a poll-leader
/// dot, account list, quick actions, and the auto-switch toggle. "Switch to best" appears only
/// when another eligible account exists, and reuses `AutoSwitchEngine`'s claim-aware scoring
/// rather than duplicating it here.
struct PanelView: View {
    @ObservedObject var state: AppState
    @ObservedObject var pool: PoolState
    @ObservedObject var router: SettingsRouter
    @State private var showShareModePrompt = false
    @State private var showInvitePopover = false
    @State private var inviteCode: String?
    @State private var isGeneratingInvite = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 4)
            accountList
            Divider().padding(.vertical, 4)
            actions
            if isPoolReady {
                Divider().padding(.vertical, 4)
                autoSwitchSettings
            }
            if let toast = state.toast {
                Divider().padding(.vertical, 4)
                Text(toast)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            if let error = state.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.crit)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
        .padding(.vertical, 10)
        .frame(width: 300)
        .background(Theme.surface)
        // Wires PoolState into AppState the moment onboarding finishes. `configurePool` is
        // idempotent for the same team, so re-evaluation here is harmless.
        .task(id: readyTeamId) {
            if case .ready(let team, let member) = pool.step {
                state.configurePool(team: team, member: member, auth: pool.auth)
            }
        }
        .confirmationDialog("Add \(state.activeAccount?.email ?? "this account") to the team pool?", isPresented: $showShareModePrompt, titleVisibility: .visible) {
            Button("Shared: teammates can switch to it") {
                Task { await state.addCurrentAccount(shareMode: .shared) }
            }
            Button("Visibility only: usage shown, token stays here") {
                Task { await state.addCurrentAccount(shareMode: .visibilityOnly) }
            }
            // Deliberately not `role: .cancel`. SwiftUI runs a cancel-role button's action on any
            // dismissal, not just an explicit tap, so clicking outside or pressing Escape used to
            // silently add the account locally and skip the pool with no feedback at all. Now
            // dismissal does nothing, and skipping the pool takes an explicit tap like the others.
            Button("Add locally only, skip the pool") {
                Task { await state.addCurrentAccount() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var readyTeamId: UUID? {
        if case .ready(let team, _) = pool.step { return team.id }
        return nil
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("Claude Code Switcher")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if isPoolReady {
                        Circle()
                            .fill(state.isPollLeader ? Theme.ok : Theme.textDim.opacity(0.4))
                            .frame(width: 6, height: 6)
                            .help(state.isPollLeader ? "This device is the poll leader" : "Another device is the poll leader")
                    } else if pool.isLocalOnlyMode {
                        offlineBadge
                    }
                }
                Text(state.activeAccount?.email ?? "Not logged in")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            if state.isSwitching {
                ProgressView().controlSize(.small).help("Switching…")
            } else if state.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await state.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
    }

    /// The visible answer to "how do I know nothing is being shared right now". Offline mode means
    /// `configurePool` is never called, so no Supabase call, Realtime subscription, or poll-leader
    /// loop ever starts. The badge makes that structural fact visible.
    private var offlineBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "wifi.slash").font(.system(size: 8))
            Text("Offline").font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(Theme.textDim)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(Theme.surface2))
        .help("Local only. Nothing leaves this Mac unless you sign in to a team.")
    }

    private var accountList: some View {
        VStack(spacing: 2) {
            if state.displayAccounts.isEmpty {
                Text("No managed accounts yet")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(state.displayAccounts) { account in
                    AccountRowView(
                        account: account,
                        isActive: account.accountUuid == state.activeAccount?.accountUuid,
                        isOwner: account.poolAccount?.ownerUserId == state.myUserId,
                        isPoolConfigured: isPoolReady,
                        onSwitch: { Task { await state.switchTo(account) } },
                        onRemove: { Task { await state.remove(account.accountUuid) } },
                        onSetShareMode: { mode in Task { await state.setShareMode(account, to: mode) } },
                        onAddToPool: { mode in Task { await state.addToPool(account, shareMode: mode) } },
                        onDemoteToLocalOnly: { Task { await state.demoteToLocalOnly(account) } },
                        onRequestReauth: { Task { await state.requestReauth(account) } }
                    )
                    .disabled(state.isSwitching)
                    .opacity(state.isSwitching ? 0.5 : 1.0)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 2) {
            if hasOtherEligibleAccounts {
                PanelActionButton(title: "Switch to best account", systemImage: "bolt.fill") {
                    Task { await state.switchToBestAccount() }
                }
                .disabled(state.isSwitching)
            }
            PanelActionButton(title: "Add current account", systemImage: "plus.circle") {
                if isPoolReady {
                    showShareModePrompt = true
                } else {
                    Task { await state.addCurrentAccount() }
                }
            }
            PanelActionButton(title: "Settings…", systemImage: "gearshape") {
                router.pane = .accounts
                WindowManager.prepareToShowWindow()
                openWindow(id: "settings")
            }
            if isTeamOwner {
                PanelActionButton(title: "Invite teammate…", systemImage: "person.badge.plus") {
                    generateInvite()
                    showInvitePopover = true
                }
                .popover(isPresented: $showInvitePopover) {
                    InvitePopoverView(
                        code: inviteCode,
                        teamKey: currentTeamKey,
                        isLoading: isGeneratingInvite,
                        errorMessage: pool.lastError,
                        onRegenerate: { generateInvite(force: true) }
                    )
                }
            }
            PanelActionButton(title: "Quit", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 4)
    }

    private var autoSwitchSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { state.autoSwitchSettings.enabled },
                set: { state.setAutoSwitchEnabled($0) }
            )) {
                Text("Auto-switch accounts").font(.system(size: 12)).foregroundStyle(Theme.text)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if state.autoSwitchSettings.enabled {
                HStack(spacing: 6) {
                    Text("Switch at").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    Picker("", selection: Binding(
                        get: { Int(state.autoSwitchSettings.threshold) },
                        set: { state.setAutoSwitchThreshold(Double($0)) }
                    )) {
                        ForEach([80, 90, 95, 98], id: \.self) { pct in
                            Text("\(pct)%").tag(pct)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 70)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var isPoolReady: Bool {
        if case .ready = pool.step { return true }
        return false
    }

    private var isTeamOwner: Bool {
        if case .ready(_, let member) = pool.step { return member.role == "owner" }
        return false
    }

    /// Handed over alongside the invite code, since `joinTeam` needs both: two different secrets
    /// with two different trust boundaries. Read from this device's Keychain rather than fetched,
    /// because it is never stored server-side.
    private var currentTeamKey: String? {
        guard case .ready(let team, _) = pool.step else { return nil }
        return pool.currentTeamKeyForSharing(team: team)
    }

    private func generateInvite(force: Bool = false) {
        guard force || inviteCode == nil else { return }  // reuse what's already showing unless forced
        isGeneratingInvite = true
        Task {
            inviteCode = await pool.createInvite()
            isGeneratingInvite = false
        }
    }

    private var hasOtherEligibleAccounts: Bool {
        state.displayAccounts.contains { $0.accountUuid != state.activeAccount?.accountUuid && $0.isActivatableHere }
    }
}

private struct InvitePopoverView: View {
    let code: String?
    let teamKey: String?
    let isLoading: Bool
    let errorMessage: String?
    let onRegenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Invite a teammate").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            Text("Send both together over text or Slack. The code is single-use and expires in 7 days. The key never touches Supabase.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDim)

            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.crit)
                }
                labeledCopyBlock(title: "Invite code", value: code)
                labeledCopyBlock(title: "Team key", value: teamKey)
                Button("Generate a new code", action: onRegenerate)
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    @ViewBuilder
    private func labeledCopyBlock(title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(Theme.textDim)
            HStack {
                Text(value ?? "unavailable")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let value {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface2))
        }
    }
}

private struct PanelActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 11)).frame(width: 14)
                Text(title).font(.system(size: 12))
                Spacer()
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Theme.surface2 : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
