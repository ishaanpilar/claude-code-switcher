import SwiftUI

/// A single labeled usage bar (used for the 5h and 7d windows). Fill color is semantic
/// (ok/warn/crit) per Theme.usageColor — the visual language the whole panel's usage display
/// relies on to be glanceable without reading numbers.
struct UsageBarView: View {
    let label: String
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 18, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.surface2)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.usageColor(forPct: window.pct))
                            .frame(width: max(2, geo.size.width * CGFloat(min(window.pct, 100) / 100)))
                    }
                }
                .frame(height: 6)

                Text("\(Int(window.pct))%")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.usageColor(forPct: window.pct))
                    .frame(width: 32, alignment: .trailing)
            }

            if let resetsInLabel = window.resetsInLabel {
                Text(resetsInLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textDim)
                    .padding(.leading, 26)
            }
        }
    }
}
