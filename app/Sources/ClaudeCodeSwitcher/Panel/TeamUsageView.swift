import SwiftUI

/// Per-user weekly digest (BUILD_PLAN.md section 8): turn count, estimated % of pool consumed,
/// top accounts. Turn counts are a far better proxy for "who used how much" than claim wall-clock
/// time — a heavy multi-file edit costs more than a one-line question, but neither the Anthropic
/// usage API (which is per-account, never per-user) nor claim duration captures that; turn count
/// at least tracks real interaction volume.
@MainActor
final class TeamUsageStats: ObservableObject {
    struct TopAccount: Identifiable {
        let email: String
        let count: Int
        var id: String { email }
    }

    struct MemberDigest: Identifiable {
        let id: UUID
        let displayName: String
        let turnCount: Int
        let sharePct: Double
        let topAccounts: [TopAccount]
    }

    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var totalTurns = 0
    @Published private(set) var members: [MemberDigest] = []

    private let poolSync = PoolSyncService()

    /// `accountsById` keys pool accounts by their Supabase row id (`turn_log.account_id`'s
    /// target) — a different key than everywhere else in the app uses (`anthropicAccountUuid`),
    /// so the caller builds it fresh from `AppState.poolAccountsByUuid` rather than this class
    /// reaching into AppState itself.
    func load(teamId: UUID, membersById: [UUID: Member], accountsById: [UUID: PoolAccount]) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let since = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date().addingTimeInterval(-7 * 86400)
            let rows = try await poolSync.fetchTurnLog(teamId: teamId, since: since)
            totalTurns = rows.count

            var byUser: [UUID: [TurnLogRow]] = [:]
            for row in rows { byUser[row.userId, default: []].append(row) }

            members = byUser.map { userId, userRows in
                var accountCounts: [UUID: Int] = [:]
                for row in userRows {
                    guard let accountId = row.accountId else { continue }
                    accountCounts[accountId, default: 0] += 1
                }
                let top = accountCounts
                    .sorted { $0.value > $1.value }
                    .prefix(3)
                    .map { TopAccount(email: accountsById[$0.key]?.email ?? "unpooled account", count: $0.value) }
                let share = totalTurns > 0 ? Double(userRows.count) / Double(totalTurns) * 100 : 0
                return MemberDigest(
                    id: userId,
                    displayName: membersById[userId]?.displayName ?? "Unknown member",
                    turnCount: userRows.count,
                    sharePct: share,
                    topAccounts: Array(top)
                )
            }.sorted { $0.turnCount > $1.turnCount }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

/// A separate window (`openWindow(id: "team-usage")` from the panel), not something crammed into
/// the menu bar dropdown — a data table doesn't belong in a quick-glance status window, and
/// BUILD_PLAN.md section 8 describes this digest as its own view. Also owns the attribution
/// hook's consent toggle: opt-in and explained here, never installed silently elsewhere.
struct TeamUsageView: View {
    @ObservedObject var state: AppState
    @ObservedObject var pool: PoolState
    @StateObject private var stats = TeamUsageStats()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            attributionSection
            Divider()
            content
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 380, idealHeight: 460)
        .background(Theme.surface)
        .task(id: teamId) { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if stats.isLoading && stats.members.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = stats.lastError {
            Text(error).font(.system(size: 12)).foregroundStyle(Theme.crit)
        } else if !state.attributionEnabled {
            Text("Turn-count attribution is off — turn it on above to start building this digest.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
        } else if stats.members.isEmpty {
            Text("No prompts logged yet in the last 7 days.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(stats.members) { member in
                        MemberDigestRow(member: member)
                    }
                }
            }
        }
    }

    private var teamId: UUID? {
        if case .ready(let team, _) = pool.step { return team.id }
        return nil
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Team usage").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Last 7 days · \(stats.totalTurns) prompts logged")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            Button { Task { await reload() } } label: {
                Image(systemName: "arrow.clockwise").foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
        }
    }

    private var attributionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { state.attributionEnabled },
                set: { state.setAttributionEnabled($0) }
            )) {
                Text("Log my prompts for attribution").font(.system(size: 12)).foregroundStyle(Theme.text)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Text("Installs a Claude Code hook that records a timestamp and which account was active on every prompt you submit — never prompt contents. Turning this off removes the hook.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDim)
        }
    }

    private func reload() async {
        guard let teamId else { return }
        let accountsById = Dictionary(uniqueKeysWithValues: state.poolAccountsByUuid.values.map { ($0.id, $0) })
        await stats.load(teamId: teamId, membersById: state.membersById, accountsById: accountsById)
    }
}

private struct MemberDigestRow: View {
    let member: TeamUsageStats.MemberDigest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(member.displayName).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Spacer()
                Text("\(member.turnCount) prompts").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                Text(String(format: "%.0f%%", member.sharePct))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            if !member.topAccounts.isEmpty {
                Text("Mostly on: " + member.topAccounts.map { "\($0.email) (\($0.count))" }.joined(separator: ", "))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface2))
    }
}
