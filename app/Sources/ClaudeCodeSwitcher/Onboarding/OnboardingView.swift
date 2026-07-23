import SwiftUI

/// Everything shown before `PoolState.step` reaches `.ready`. One view with a switch over the
/// step, rather than a NavigationStack of separate screens — this whole thing lives inside a
/// `MenuBarExtra` dropdown (BUILD_PLAN.md section 7), where a full navigation chrome would be
/// out of place; a single fixed-width panel that reshapes its content is the same idiom PanelView
/// itself uses.
struct OnboardingView: View {
    @ObservedObject var pool: PoolState
    @ObservedObject var router: SettingsRouter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !isChecking {
                tosCaveat
            }
            content
            if let error = pool.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.crit)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 300)
        .background(Theme.surface)
    }

    private var header: some View {
        Text("Claude Code Switcher")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.text)
    }

    /// Present on every onboarding step (not just sign-in) — without this, someone signed in but
    /// not yet on a team (`.needsTeamSetup`) or missing their team key (`.needsTeamKey`) had no way
    /// to reach About or even quit the app short of Force Quit: this is a `MenuBarExtra` accessory
    /// app with no Dock icon and no standard app menu, so there's no other Quit anywhere on these
    /// screens.
    private var footer: some View {
        HStack {
            Button {
                router.pane = .about
                WindowManager.prepareToShowWindow()
                openWindow(id: "settings")
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textDim)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textDim)
        }
    }

    private var isChecking: Bool {
        if case .checking = pool.step { return true }
        return false
    }

    /// BUILD_PLAN.md section 5's honest caveat, surfaced in onboarding rather than buried —
    /// "do not add anything that evades detection; just be transparent." Pooling one
    /// subscription across a group cuts against consumer ToS and can look anomalous to
    /// Anthropic's systems; the app doesn't try to hide or work around that.
    private var tosCaveat: some View {
        Text("Heads up: sharing one subscription across several people and IPs cuts against Anthropic's consumer terms and can look anomalous to their systems — the larger the group, the stronger that signal. This app does nothing to hide or evade that; use it with people you trust to accept the risk together.")
            .font(.system(size: 9))
            .foregroundStyle(Theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        switch pool.step {
        case .checking:
            ProgressView().controlSize(.small)
        case .signedOut:
            SignInStep(pool: pool)
        case .awaitingCode(let email):
            CodeEntryStep(pool: pool, email: email)
        case .needsTeamSetup:
            TeamSetupStep(pool: pool)
        case .needsTeamKey(let team):
            TeamKeyRecoveryStep(pool: pool, team: team)
        case .ready, .localOnly:
            EmptyView()  // RootView switches to PanelView before either of these ever renders
        }
    }
}

private struct SignInStep: View {
    @ObservedObject var pool: PoolState
    @State private var email = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sign in with your email to join or start a team.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
            TextField("you@example.com", text: $email)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            Button {
                Task { await pool.sendCode(email: email) }
            } label: {
                if pool.isBusy {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else {
                    Text("Send code").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(email.isEmpty || pool.isBusy)

            Divider().padding(.vertical, 2)

            Text("Just juggling your own accounts? Skip the cloud entirely.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDim)
            Button("Use locally, without an account") { pool.enableLocalOnly() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
    }
}

private struct CodeEntryStep: View {
    @ObservedObject var pool: PoolState
    let email: String
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter the 6-digit code sent to \(email).")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
            TextField("123456", text: $code)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            Button {
                Task { await pool.verifyCode(code, email: email) }
            } label: {
                if pool.isBusy {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else {
                    Text("Verify").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(code.count < 6 || pool.isBusy)
            Button("Use a different email") { pool.backToSignIn() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
        }
    }
}

private struct TeamSetupStep: View {
    @ObservedObject var pool: PoolState
    @State private var mode: Mode = .create
    @State private var teamName = ""
    @State private var inviteCode = ""
    @State private var teamKeyInput = ""
    @State private var createdTeamKey: String?

    enum Mode: String, CaseIterable { case create = "Create team", join = "Join team" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let createdTeamKey {
                createdSuccessView(key: createdTeamKey)
            } else {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if mode == .create {
                    createForm
                } else {
                    joinForm
                }

                Divider().padding(.vertical, 2)

                Text("Changed your mind about a team? Switch to juggling your own accounts locally instead.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                Button("Use locally, without an account") { pool.enableLocalOnly() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name your team's pool.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
            TextField("e.g. Weekend Squad", text: $teamName)
                .textFieldStyle(.roundedBorder)
            Button {
                Task {
                    await pool.createTeam(name: teamName)
                    if case .ready(let team, _) = pool.step {
                        createdTeamKey = pool.currentTeamKeyForSharing(team: team)
                    }
                }
            } label: {
                if pool.isBusy {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else {
                    Text("Create").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(teamName.isEmpty || pool.isBusy)
        }
    }

    private func createdSuccessView(key: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Team created. Share this key with teammates when they join — it's the only copy, and it never leaves your devices' Keychains otherwise.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
            Text(key)
                .font(.system(size: 10, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface2))
                .textSelection(.enabled)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(key, forType: .string)
            }
        }
    }

    private var joinForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask your team owner for an invite code (panel → \"Invite teammate…\") and the team key.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
            TextField("Invite code", text: $inviteCode)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            TextField("Team key", text: $teamKeyInput)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            Button {
                Task { await pool.joinTeam(code: inviteCode, teamKeyString: teamKeyInput) }
            } label: {
                if pool.isBusy {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else {
                    Text("Join").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(inviteCode.isEmpty || teamKeyInput.isEmpty || pool.isBusy)
        }
    }
}

private struct TeamKeyRecoveryStep: View {
    @ObservedObject var pool: PoolState
    let team: Team
    @State private var teamKeyInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You're a member of \"\(team.name)\", but this device doesn't have its team key yet. Paste it below (ask a teammate if you don't have it saved).")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
            TextField("Team key", text: $teamKeyInput)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            Button {
                Task { await pool.enterTeamKey(teamKeyInput, team: team) }
            } label: {
                if pool.isBusy {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else {
                    Text("Continue").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(teamKeyInput.isEmpty || pool.isBusy)
        }
    }
}
