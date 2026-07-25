import SwiftUI

/// One account card in the panel's list, rendering a merged `DisplayAccount`: local-only, pool
/// visibility-only, or pool shared, each with a slightly different affordance.
struct AccountRowView: View {
    let account: DisplayAccount
    let isActive: Bool
    let isOwner: Bool
    /// Whether a team is wired up at all. In offline mode every account is local by definition, so
    /// the "local only" badge would be noise on every row rather than a distinction.
    let isPoolConfigured: Bool
    let onSwitch: () -> Void
    let onRemove: () -> Void
    let onSetShareMode: (ShareMode) -> Void
    let onAddToPool: (ShareMode) -> Void
    let onDemoteToLocalOnly: () -> Void
    let onRequestReauth: () -> Void

    /// An account this Mac holds that has no pool row: real state, not an absence. Worth its own
    /// badge, since it was previously signalled only by the *lack* of a shared/visibility icon.
    private var isLocalOnly: Bool { isPoolConfigured && account.poolAccount == nil && account.isLocallyKnown }

    @State private var isHovering = false

    var body: some View {
        // The trash button must stay a sibling of the switch button, not nested inside its label:
        // SwiftUI doesn't reliably route taps to an inner Button inside another Button's hit area,
        // so nesting made it dead. The switch button's own `.contentShape(Rectangle())` is what
        // keeps click-anywhere-on-the-row-to-switch working.
        HStack(spacing: 10) {
            Button(action: onSwitch) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(isActive ? Theme.accent : .clear)
                        .frame(width: 6, height: 6)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(account.email)
                                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                                .foregroundStyle(Theme.text)
                            shareBadge
                        }

                        if let usage = account.usage {
                            VStack(alignment: .leading, spacing: 2) {
                                if let fiveHour = usage.fiveHour {
                                    UsageBarView(label: "5h", window: fiveHour)
                                }
                                if let sevenDay = usage.sevenDay {
                                    UsageBarView(label: "7d", window: sevenDay)
                                }
                            }
                        } else {
                            Text("usage unavailable")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textDim)
                        }

                        if account.poolAccount?.status == .quarantined {
                            Text(isOwner ? "needs re-login" : "needs re-login (right-click to notify the owner)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.crit)
                        } else if account.claimedByMe {
                            // Your own reservation is information, not an obstacle, so it reads as
                            // such. Rendering it in the same warning style as a teammate's made an
                            // account you were happily using look blocked.
                            Text("reserved by you")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textDim)
                        } else if let claimedByName = account.claimedByName {
                            Text("held by \(claimedByName)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.warn)
                        } else if !account.isActivatableHere {
                            Text("visibility only, owner must switch to it")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textDim)
                        } else if isLocalOnly {
                            Text("this Mac only, not in the pool")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textDim)
                        }
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!account.isActivatableHere)

            if isHovering && account.isLocallyKnown {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Theme.surface2 : .clear)
        )
        .opacity(account.isActivatableHere ? 1.0 : 0.6)
        .onHover { isHovering = $0 }
        .contextMenu {
            if isLocalOnly {
                // Without these the menu was empty for a local-only account, and `setShareMode`
                // silently no-ops on one, so the choice made in the add dialog could never be
                // revisited.
                Button("Share with team") { onAddToPool(.shared) }
                Button("Add as visibility only") { onAddToPool(.visibilityOnly) }
            } else if isOwner, let poolAccount = account.poolAccount {
                Button("Share with team") { onSetShareMode(.shared) }
                    .disabled(poolAccount.shareMode == .shared)
                Button("Visibility only") { onSetShareMode(.visibilityOnly) }
                    .disabled(poolAccount.shareMode == .visibilityOnly)
                // Only offered where a local copy exists to fall back to; otherwise leaving the
                // pool would mean losing the account rather than demoting it.
                if account.isLocallyKnown {
                    Divider()
                    Button("Take out of pool, keep on this Mac") { onDemoteToLocalOnly() }
                }
            } else if !isOwner, account.poolAccount != nil {
                // Not gated on already being quarantined: the person noticing a problem is often
                // ahead of the app's own diagnosis (see AppState.requestReauth).
                Button("Request re-login…", action: onRequestReauth)
            }
        }
    }

    @ViewBuilder
    private var shareBadge: some View {
        if let mode = account.poolAccount?.shareMode {
            Image(systemName: mode == .shared ? "lock.open" : "eye")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textDim)
                .help(mode == .shared
                      ? "Shared with the team. Teammates can switch to it."
                      : "Visible to the team, but the login stays on this Mac.")
        } else if isLocalOnly {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textDim)
                .help("On this Mac only. Not in the team pool, and teammates can't see it. Right-click to add it.")
        }
    }
}
