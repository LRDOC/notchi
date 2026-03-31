import SwiftUI

struct UsageBarView: View {
    let usage: QuotaPeriod?
    let isLoading: Bool
    let error: String?
    let statusMessage: String?
    let isStale: Bool
    let recoveryAction: ClaudeUsageRecoveryAction
    var compact: Bool = false
    var isEnabled: Bool = AppSettings.isUsageEnabled
    var onConnect: (() -> Void)?
    var onRetry: (() -> Void)?

    var actionHint: String? {
        switch recoveryAction {
        case .retry:
            return "(tap to retry)"
        case .reconnect, .waitForClaudeCode, .none:
            return nil
        }
    }

    private var effectivePercentage: Int {
        guard let usage, !usage.isExpired else { return 0 }
        return usage.usagePercentage
    }

    private var usageColor: Color {
        guard usage != nil else { return TerminalColors.dimmedText }
        if isStale { return TerminalColors.dimmedText }
        switch effectivePercentage {
        case ..<50: return TerminalColors.green
        case ..<80: return TerminalColors.amber
        default: return TerminalColors.red
        }
    }

    var shouldShowConnectPlaceholder: Bool {
        !isEnabled
            && usage == nil
            && !isLoading
            && error == nil
            && statusMessage == nil
            && !isStale
            && recoveryAction == .none
    }

    var shouldAllowTapAction: Bool {
        switch recoveryAction {
        case .reconnect, .waitForClaudeCode:
            return true
        case .retry:
            return usage == nil
        case .none:
            return false
        }
    }

    var body: some View {
        if shouldShowConnectPlaceholder {
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
            .padding(.top, 3)
            .padding(.leading, 2)
            .padding(.bottom, -7)
        } else {
            connectedView
        }
    }

    private var connectedView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let error, usage == nil {
                    HStack(spacing: 4) {
                        Text(error)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(TerminalColors.dimmedText)
                        if let actionHint {
                            Text(actionHint)
                                .font(.system(size: 10))
                                .foregroundColor(TerminalColors.dimmedText)
                        }
                    }
                } else if let usage, let resetTime = usage.formattedResetTime {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("Resets in \(resetTime)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(TerminalColors.secondaryText)
                            .lineLimit(1)
                        if let statusMessage {
                            Text("• \(statusMessage)")
                                .font(.system(size: 9))
                                .foregroundColor(TerminalColors.dimmedText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                } else if let statusMessage, usage != nil {
                    Text(statusMessage)
                        .font(.system(size: 10))
                        .foregroundColor(TerminalColors.dimmedText)
                } else {
                    Text("Claude Usage")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(TerminalColors.secondaryText)
                }
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else if usage != nil {
                    Text("\(effectivePercentage)%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(usageColor)
                }
            }

            progressBar
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard shouldAllowTapAction else { return }
            switch recoveryAction {
            case .retry:
                onRetry?()
            case .reconnect, .waitForClaudeCode:
                onConnect?()
            case .none:
                break
            }
        }
        .padding(.top, compact ? 0 : 5)
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(TerminalColors.subtleBackground)

                if usage != nil {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(usageColor)
                        .frame(width: geometry.size.width * Double(effectivePercentage) / 100)
                }
            }
        }
        .frame(height: 4)
    }

}
