import SwiftUI

struct UsageBarView: View {
    let usage: QuotaPeriod?
    let isLoading: Bool
    let error: String?
    var compact: Bool = false
    var onConnect: (() -> Void)?

    private var isStale: Bool {
        error != nil && usage != nil
    }

    private var usageColor: Color {
        guard let usage else { return TerminalColors.dimmedText }
        if isStale { return TerminalColors.dimmedText }
        switch usage.usagePercentage {
        case ..<50: return TerminalColors.green
        case ..<80: return TerminalColors.amber
        default: return TerminalColors.red
        }
    }

    var body: some View {
        if !AppSettings.isUsageEnabled {
            Button(action: { onConnect?() }) {
                HStack(spacing: 4) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 10))
                    Text("Tap to show Claude usage")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(TerminalColors.dimmedText)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.bottom, -10)
        } else {
            connectedView
        }
    }

    private var connectedView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if error != nil, usage == nil {
                    Button(action: { onConnect?() }) {
                        Text("Tap to connect usage tracking")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(TerminalColors.dimmedText)
                } else if let usage, let resetTime = usage.formattedResetTime {
                    HStack(spacing: 4) {
                        Text("Resets in \(resetTime)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(TerminalColors.secondaryText)
                        if isStale {
                            Text("(cached)")
                                .font(.system(size: 10))
                                .foregroundColor(TerminalColors.dimmedText)
                        }
                    }
                } else {
                    Text("Claude Usage")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(TerminalColors.secondaryText)
                }
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else if let usage {
                    Text("\(usage.usagePercentage)%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(usageColor)
                }
            }

            progressBar
        }
        .padding(.top, compact ? 0 : 5)
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(TerminalColors.subtleBackground)

                if let usage {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(usageColor)
                        .frame(width: geometry.size.width * Double(usage.usagePercentage) / 100)
                }
            }
        }
        .frame(height: 4)
    }

}
