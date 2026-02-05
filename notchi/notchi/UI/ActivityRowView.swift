import Combine
import SwiftUI

struct ActivityRowView: View {
    let event: SessionEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                bullet
                toolName
                if event.status != .running {
                    statusLabel
                }
            }

            if let description = event.description {
                Text(description)
                    .font(.system(size: 12).italic())
                    .foregroundColor(TerminalColors.dimmedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 16)
            }
        }
        .padding(.vertical, 6)
    }

    private var bullet: some View {
        Circle()
            .fill(bulletColor)
            .frame(width: 5, height: 5)
    }

    private var bulletColor: Color {
        switch event.status {
        case .running: return TerminalColors.amber
        case .success: return TerminalColors.green
        case .error: return TerminalColors.red
        }
    }

    private var toolName: some View {
        Text(event.tool ?? event.type)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(TerminalColors.primaryText)
    }

    private var statusLabel: some View {
        let isSuccess = event.status == .success
        return Text(isSuccess ? "Completed" : "Failed")
            .font(.system(size: 12))
            .foregroundColor(isSuccess ? TerminalColors.secondaryText : TerminalColors.red)
    }
}

struct WorkingIndicatorView: View {
    let state: NotchiState
    @State private var dotCount = 1
    @State private var symbolPhase = 0

    private let symbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private let dotsTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    private let symbolTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    private var dots: String {
        String(repeating: ".", count: dotCount)
    }

    private var isDone: Bool {
        state == .happy
    }

    private var statusText: String {
        switch state {
        case .compacting: return "Compacting"
        default: return "Clanking"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if isDone {
                Text("✓")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(TerminalColors.green)
                    .frame(width: 14, alignment: .center)
                Text("Done!")
                    .font(.system(size: 13, weight: .medium).italic())
                    .foregroundColor(TerminalColors.green)
            } else {
                Text(symbols[symbolPhase])
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(TerminalColors.claudeOrange)
                    .frame(width: 14, alignment: .center)
                Text("\(statusText)\(dots)")
                    .font(.system(size: 13, weight: .medium).italic())
                    .foregroundColor(TerminalColors.claudeOrange)
            }
        }
        .padding(.vertical, 6)
        .onReceive(dotsTimer) { _ in
            if !isDone { dotCount = (dotCount % 3) + 1 }
        }
        .onReceive(symbolTimer) { _ in
            if !isDone { symbolPhase = (symbolPhase + 1) % symbols.count }
        }
    }
}
