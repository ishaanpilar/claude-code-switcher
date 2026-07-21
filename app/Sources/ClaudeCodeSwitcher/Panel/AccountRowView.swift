import SwiftUI

/// One account card in the panel's list, rendering a merged `DisplayAccount` — local-only, pool
/// visibility-only, or pool shared, each with a slightly different affordance (see
/// `isActivatableHere` / the claimed-by badge below).
struct AccountRowView: View {
    let account: DisplayAccount
    let isActive: Bool
    let isOwner: Bool
    let onSwitch: () -> Void
    let onRemove: () -> Void
    let onSetShareMode: (ShareMode) -> Void
    let onRequestReauth: () -> Void

    @State private var isHovering = false

    var body: some View {
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
                        Text(isOwner ? "needs re-login" : "needs re-login — right-click to notify the owner")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.crit)
                    } else if let claimedByName = account.claimedByName {
                        Text("held by \(claimedByName)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.warn)
                    } else if !account.isActivatableHere {
                        Text("visibility-only — owner must switch to it")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textDim)
                    }
                }

                Spacer(minLength: 8)

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
        }
        .buttonStyle(.plain)
        .disabled(!account.isActivatableHere)
        .onHover { isHovering = $0 }
        .contextMenu {
            if isOwner, let poolAccount = account.poolAccount {
                Button("Share with team") { onSetShareMode(.shared) }
                    .disabled(poolAccount.shareMode == .shared)
                Button("Visibility only") { onSetShareMode(.visibilityOnly) }
                    .disabled(poolAccount.shareMode == .visibilityOnly)
            } else if !isOwner, account.poolAccount != nil {
                // Not gated on already being quarantined — the person noticing a problem is
                // often ahead of the app's own diagnosis (see AppState.requestReauth).
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
        }
    }
}
