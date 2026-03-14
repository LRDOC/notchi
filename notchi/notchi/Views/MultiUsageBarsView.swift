import SwiftUI

struct MultiUsageBarsView: View {
    let claudeUsage: QuotaPeriod?
    let claudeLoading: Bool
    let claudeError: String?
    var claudeEnabled: Bool = AppSettings.isUsageEnabled
    let codexUsage: CodexUsageSnapshot?
    let geminiUsage: GeminiUsageSnapshot?
    let localLoading: Bool
    var compact: Bool = false
    var onClaudeConnect: (() -> Void)?
    var onClaudeRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            claudeRow
            codexRow
            geminiRow
        }
        .padding(.top, compact ? 0 : 5)
    }

    private var claudeRow: some View {
        if !claudeEnabled {
            return AnyView(
                labeledRow(
                    source: .claude,
                    value: 0,
                    text: "Tap to connect",
                    action: onClaudeConnect
                )
            )
        }

        let percent = claudeUsage?.usagePercentage ?? 0
        let resetText = claudeUsage?.formattedResetTime
        let statusText: String

        if let error = claudeError, claudeUsage == nil {
            statusText = error
        } else if let resetText {
            statusText = "Reset \(resetText) • \(percent)%"
        } else if claudeLoading {
            statusText = "Loading..."
        } else {
            statusText = "\(percent)%"
        }

        return AnyView(
            labeledRow(
                source: .claude,
                value: Double(percent) / 100,
                text: statusText,
                action: claudeError != nil ? onClaudeRetry : nil
            )
        )
    }

    private var codexRow: some View {
        let percent = codexUsage?.effectivePercentage ?? 0
        let value = min(max(Double(percent) / 100, 0), 1)

        let statusText: String
        if let usage = codexUsage {
            if let reset = usage.formattedResetTime, let p = usage.effectivePercentage {
                statusText = "Reset \(reset) • \(p)%"
            } else if let p = usage.effectivePercentage {
                statusText = "\(p)% • \(formatTokens(usage.totalTokens)) tok"
            } else {
                statusText = "\(formatTokens(usage.totalTokens)) tok"
            }
        } else if localLoading {
            statusText = "Loading..."
        } else {
            statusText = "No data"
        }

        return labeledRow(
            source: .codex,
            value: value,
            text: statusText,
            action: nil
        )
    }

    private var geminiRow: some View {
        let contextTokens = (geminiUsage?.inputTokens ?? 0) + (geminiUsage?.outputTokens ?? 0)
        let approxContextWindow = 1_000_000.0
        let value = min(max(Double(contextTokens) / approxContextWindow, 0), 1)

        let statusText: String
        if let usage = geminiUsage {
            let contextPercent = Int((value * 100).rounded())
            var parts = [
                "I \(formatCompactTokens(usage.inputTokens))",
                "O \(formatCompactTokens(usage.outputTokens))"
            ]
            if usage.cachedTokens > 0 {
                parts.append("C \(formatCompactTokens(usage.cachedTokens))")
            }
            statusText = "~\(contextPercent)% ctx • " + parts.joined(separator: " • ")
        } else if localLoading {
            statusText = "Loading..."
        } else {
            statusText = "No data"
        }

        return labeledRow(
            source: .gemini,
            value: value,
            text: statusText,
            action: nil
        )
    }

    private func labeledRow(
        source: AIToolSource,
        value: Double,
        text: String,
        action: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(source.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(source.badgeColor)

                Spacer()

                if let action {
                    Button(action: action) {
                        Text(text)
                            .font(.system(size: 10))
                            .foregroundColor(TerminalColors.dimmedText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .minimumScaleFactor(0.9)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(text)
                        .font(.system(size: 10))
                        .foregroundColor(TerminalColors.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.9)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(TerminalColors.subtleBackground)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(source.badgeColor)
                        .frame(width: geometry.size.width * value)
                }
            }
            .frame(height: 3)
        }
    }

    private func formatTokens(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatCompactTokens(_ value: Int) -> String {
        let number = Double(value)
        let absNumber = abs(number)

        if absNumber >= 1_000_000_000 {
            return String(format: "%.1fB", number / 1_000_000_000)
        }
        if absNumber >= 1_000_000 {
            return String(format: "%.1fM", number / 1_000_000)
        }
        if absNumber >= 1_000 {
            return String(format: "%.1fK", number / 1_000)
        }
        return "\(value)"
    }
}
