import ServiceManagement
import SwiftUI

struct PanelSettingsView: View {
    @AppStorage(AppSettings.hideSpriteWhenIdleKey) private var hideSpriteWhenIdle = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var installedTools: [AIToolSource] = []
    @State private var installErrors: [AIToolSource: String] = [:]
    @State private var toolEnabled: [AIToolSource: Bool] = Dictionary(
        uniqueKeysWithValues: AIToolSource.allCases.map { ($0, AppSettings.isToolEnabled($0)) }
    )
    @State private var apiKeyInput = AppSettings.anthropicApiKey ?? ""
    @State private var localUsageService: LocalUsageService = .shared
    @ObservedObject private var updateManager = UpdateManager.shared
    private var usageConnected: Bool { ClaudeUsageService.shared.isConnected }
    private var hasApiKey: Bool { !apiKeyInput.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    displaySection
                    Divider().background(Color.white.opacity(0.08))
                    togglesSection
                    Divider().background(Color.white.opacity(0.08))
                    actionsSection
                }
                .padding(.top, 10)
            }
            .scrollIndicators(.hidden)

            Spacer()

            quitSection
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            refreshHookStatus()
            refreshLocalUsage()
        }
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenPickerRow(screenSelector: ScreenSelector.shared)

            SoundPickerView()
        }
    }

    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: toggleLaunchAtLogin) {
                SettingsRowView(icon: "power", title: "Launch at Login") {
                    ToggleSwitch(isOn: launchAtLogin)
                }
            }
            .buttonStyle(.plain)

            Button(action: installAllHooks) {
                SettingsRowView(icon: "terminal", title: "Hooks") {
                    hooksStatusBadge
                }
            }
            .buttonStyle(.plain)

            Button(action: toggleHideSpriteWhenIdle) {
                SettingsRowView(icon: "eye.slash", title: "Hide Sprite When Idle") {
                    ToggleSwitch(isOn: hideSpriteWhenIdle)
                }
            }
            .buttonStyle(.plain)

            ForEach(AIToolSource.allCases, id: \.rawValue) { source in
                toolToggleRow(source)
            }

            if !installErrors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(AIToolSource.allCases.filter { installErrors[$0] != nil }, id: \.rawValue) { source in
                        Text("\(source.displayName): \(installErrors[source] ?? "")")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(TerminalColors.red)
                    }
                }
                .padding(.leading, 12)
            }

            Button(action: connectUsage) {
                SettingsRowView(icon: "gauge.with.dots.needle.33percent", title: "Claude Usage") {
                    statusBadge(
                        usageConnected ? "Connected" : "Not Connected",
                        color: usageConnected ? TerminalColors.green : TerminalColors.red
                    )
                }
            }
            .buttonStyle(.plain)

            Button(action: refreshLocalUsage) {
                SettingsRowView(icon: "codex_settings_icon", title: "Codex Usage", iconIsAsset: true) {
                    statusBadge(codexUsageLabel, color: codexUsageColor)
                }
            }
            .buttonStyle(.plain)

            Button(action: refreshLocalUsage) {
                SettingsRowView(icon: "gemini_settings_icon", title: "Gemini Usage", iconIsAsset: true) {
                    statusBadge(geminiUsageLabel, color: geminiUsageColor)
                }
            }
            .buttonStyle(.plain)

            apiKeyRow
        }
    }

    private var codexUsageLabel: String {
        if localUsageService.isLoading && localUsageService.codexUsage == nil {
            return "Loading..."
        }
        guard let usage = localUsageService.codexUsage else {
            return "No data"
        }
        if let reset = usage.formattedResetTime, let percent = usage.effectivePercentage {
            return "Reset \(reset) • \(percent)%"
        }
        if let percent = usage.effectivePercentage {
            return "\(percent)% • \(formatCompactTokens(usage.totalTokens)) tok"
        }
        return "\(formatCompactTokens(usage.totalTokens)) tok"
    }

    private var codexUsageColor: Color {
        guard let percent = localUsageService.codexUsage?.effectivePercentage else {
            return localUsageService.codexUsage == nil ? TerminalColors.dimmedText : TerminalColors.secondaryText
        }
        return usageColor(for: percent)
    }

    private var geminiUsageLabel: String {
        if localUsageService.isLoading && localUsageService.geminiUsage == nil {
            return "Loading..."
        }
        guard let usage = localUsageService.geminiUsage else {
            return "No data"
        }
        let contextTokens = usage.inputTokens + usage.outputTokens
        let contextPercent = Int((min(max(Double(contextTokens) / 1_000_000.0, 0), 1) * 100).rounded())
        return "~\(contextPercent)% ctx • I \(formatCompactTokens(usage.inputTokens)) • O \(formatCompactTokens(usage.outputTokens))"
    }

    private var geminiUsageColor: Color {
        guard let usage = localUsageService.geminiUsage else { return TerminalColors.dimmedText }
        let contextTokens = usage.inputTokens + usage.outputTokens
        let contextPercent = Int((min(max(Double(contextTokens) / 1_000_000.0, 0), 1) * 100).rounded())
        return usageColor(for: contextPercent)
    }

    private var apiKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsRowView(icon: "brain", title: "Emotion Analysis") {
                statusBadge(
                    hasApiKey ? "Active" : "No Key",
                    color: hasApiKey ? TerminalColors.green : TerminalColors.red
                )
            }

            HStack(spacing: 6) {
                SecureField("", text: $apiKeyInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(TerminalColors.primaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(6)
                    .onSubmit { saveApiKey() }
                    .overlay(alignment: .leading) {
                        if apiKeyInput.isEmpty {
                            Text("Anthropic API Key")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(TerminalColors.dimmedText)
                                .padding(.leading, 8)
                                .allowsHitTesting(false)
                        }
                    }

                Button(action: saveApiKey) {
                    Image(systemName: hasApiKey ? "checkmark.circle.fill" : "arrow.right.circle")
                        .font(.system(size: 14))
                        .foregroundColor(hasApiKey ? TerminalColors.green : TerminalColors.dimmedText)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 28)
        }
    }

    private func saveApiKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.anthropicApiKey = trimmed.isEmpty ? nil : trimmed
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: handleUpdatesAction) {
                SettingsRowView(icon: "arrow.triangle.2.circlepath", title: "Check for Updates") {
                    updateStatusView
                }
            }
            .buttonStyle(.plain)

            Button(action: openGitHubRepo) {
                SettingsRowView(icon: "star", title: "Star on GitHub") {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10))
                        .foregroundColor(TerminalColors.dimmedText)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func openGitHubRepo() {
        NSWorkspace.shared.open(URL(string: "https://github.com/sk-ruban/notchi")!)
    }

    private func openLatestReleasePage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/sk-ruban/notchi/releases/latest")!)
    }

    private var quitSection: some View {
        Button(action: {
            NSApplication.shared.terminate(nil)
        }) {
            HStack {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 13))
                Text("Quit Notchi")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(TerminalColors.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(TerminalColors.red.opacity(0.1))
            .contentShape(Rectangle())
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }

    private func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            print("Failed to toggle launch at login: \(error)")
        }
    }

    private func connectUsage() {
        ClaudeUsageService.shared.connectAndStartPolling()
    }

    private func toggleHideSpriteWhenIdle() {
        hideSpriteWhenIdle.toggle()
    }

    private func handleUpdatesAction() {
        if case .upToDate = updateManager.state {
            openLatestReleasePage()
        } else {
            updateManager.checkForUpdates()
        }
    }

    private func refreshLocalUsage() {
        Task { await localUsageService.refreshAll() }
    }

    private var hooksStatusBadge: some View {
        Group {
            if !installErrors.isEmpty {
                statusBadge("Issues", color: TerminalColors.red)
            } else if installedTools.isEmpty {
                statusBadge("Not Installed", color: TerminalColors.red)
            } else {
                Text(installedTools.map(\.displayName).joined(separator: ", "))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(TerminalColors.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(TerminalColors.green.opacity(0.15))
                    .cornerRadius(4)
            }
        }
    }

    @ViewBuilder
    private func toolToggleRow(_ source: AIToolSource) -> some View {
        let isInstalled = installedTools.contains(source)
        let isOn = toolEnabled[source] ?? true
        let issue = installErrors[source]
        let isToolAvailable = HookInstallerCoordinator.installer(for: source)?.isToolAvailable ?? false

        Button(action: {
            if isInstalled {
                let newValue = !(toolEnabled[source] ?? true)
                AppSettings.setToolEnabled(source, newValue)
                toolEnabled[source] = newValue
            } else {
                installTool(source)
            }
        }) {
            SettingsRowView(icon: iconName(for: source), title: source.displayName, iconIsAsset: true) {
                if isInstalled {
                    ToggleSwitch(isOn: isOn)
                } else if issue != nil {
                    statusBadge("Unsupported", color: TerminalColors.red)
                } else if !isToolAvailable {
                    statusBadge("Not Found", color: TerminalColors.dimmedText)
                } else {
                    statusBadge("Install", color: TerminalColors.dimmedText)
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(isInstalled || issue != nil ? 1.0 : 0.6)
        .padding(.leading, 12)
    }

    private func iconName(for source: AIToolSource) -> String {
        switch source {
        case .claude: return "claude_settings_icon"
        case .codex: return "codex_settings_icon"
        case .gemini: return "gemini_settings_icon"
        }
    }

    private func installAllHooks() {
        Task(priority: .userInitiated) {
            var issues = HookInstallerCoordinator.compatibilityIssues()
            for source in AIToolSource.allCases {
                guard let installer = HookInstallerCoordinator.installer(for: source) else { continue }
                let result = installer.installIfNeeded()
                if case .failed(let error) = result {
                    issues[source] = error.localizedDescription
                }
            }
            installErrors = issues
            refreshHookStatus()
        }
    }

    private func installTool(_ source: AIToolSource) {
        Task(priority: .userInitiated) {
            guard let installer = HookInstallerCoordinator.installer(for: source) else { return }
            let result = installer.installIfNeeded()
            if case .failed(let error) = result {
                installErrors[source] = error.localizedDescription
            } else {
                installErrors.removeValue(forKey: source)
            }
            refreshHookStatus()
        }
    }

    private func refreshHookStatus() {
        Task(priority: .userInitiated) {
            let tools = HookInstallerCoordinator.installedTools()
            let issues = HookInstallerCoordinator.compatibilityIssues()
            installedTools = tools
            for (source, message) in issues {
                installErrors[source] = message
            }
            let installed = Set(tools)
            for source in AIToolSource.allCases where installed.contains(source) {
                installErrors.removeValue(forKey: source)
            }
        }
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
            .frame(maxWidth: 160, alignment: .trailing)
    }

    private func usageColor(for percentage: Int) -> Color {
        switch percentage {
        case ..<50: return TerminalColors.green
        case ..<80: return TerminalColors.amber
        default: return TerminalColors.red
        }
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

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateManager.state {
        case .checking:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Checking...")
                    .font(.system(size: 10))
                    .foregroundColor(TerminalColors.dimmedText)
            }
        case .upToDate:
            statusBadge("Up to date", color: TerminalColors.green)
        case .updateAvailable:
            statusBadge("Update available", color: TerminalColors.amber)
        case .downloading:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Downloading...")
                    .font(.system(size: 10))
                    .foregroundColor(TerminalColors.dimmedText)
            }
        case .readyToInstall:
            statusBadge("Ready to install", color: TerminalColors.green)
        case .error(let failure):
            statusBadge(failure.label, color: TerminalColors.red)
        case .idle:
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .font(.system(size: 10))
                .foregroundColor(TerminalColors.dimmedText)
        }
    }
}

struct SettingsRowView<Trailing: View>: View {
    let icon: String
    let title: String
    var iconIsAsset: Bool = false
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack {
            Group {
                if iconIsAsset {
                    Image(icon)
                        .resizable()
                        .interpolation(.none)
                        .renderingMode(.original)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundColor(TerminalColors.secondaryText)
                }
            }
            .frame(width: 20)

            Text(title)
                .font(.system(size: 12))
                .foregroundColor(TerminalColors.primaryText)

            Spacer()

            trailing()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct ToggleSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? TerminalColors.green : Color.white.opacity(0.15))
                .frame(width: 32, height: 18)

            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .padding(2)
        }
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }
}

#Preview {
    PanelSettingsView()
        .frame(width: 402, height: 400)
        .background(Color.black)
}
