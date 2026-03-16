import SwiftUI

enum ActivityItem: Identifiable {
    case tool(SessionEvent)
    case assistant(AssistantMessage)

    var id: String {
        switch self {
        case .tool(let event): return "tool-\(event.id.uuidString)"
        case .assistant(let msg): return "assistant-\(msg.id)"
        }
    }

    var timestamp: Date {
        switch self {
        case .tool(let event): return event.timestamp
        case .assistant(let msg): return msg.timestamp
        }
    }
}

struct ExpandedPanelView: View {
    let sessionStore: SessionStore
    let usageService: ClaudeUsageService
    let localUsageService: LocalUsageService
    @Binding var showingSettings: Bool
    @Binding var showingSessionActivity: Bool
    @Binding var isActivityCollapsed: Bool
    let topVisualClearance: CGFloat

    private var effectiveSession: SessionData? {
        sessionStore.effectiveSession
    }

    private var state: NotchiState {
        effectiveSession?.state ?? .idle
    }

    private var showIndicator: Bool {
        state.task == .working || state.task == .compacting || state.task == .waiting
    }

    private var hasActivity: Bool {
        guard let session = effectiveSession else { return false }
        return !unifiedActivityItems.isEmpty ||
               session.isProcessing ||
               showIndicator ||
               session.lastUserPrompt != nil ||
               !session.pendingQuestions.isEmpty
    }

    private var unifiedActivityItems: [ActivityItem] {
        guard let session = effectiveSession else { return [] }

        let filteredToolEvents = session.recentEvents
            .filter { $0.type != "UserPromptSubmit" }

        let filteredMessages = session.recentAssistantMessages

        let toolItems = filteredToolEvents
            .map { ActivityItem.tool($0) }
        let messageItems = filteredMessages.map { ActivityItem.assistant($0) }
        return (toolItems + messageItems).sorted { $0.timestamp < $1.timestamp }
    }

    private var shouldShowSessionPicker: Bool {
        sessionStore.activeSessionCount >= 2 && !showingSessionActivity
    }

    private var usageRefreshTrigger: String {
        let sessions = sessionStore.sortedSessions
            .map {
                "\($0.id):\($0.source.rawValue):\($0.recentEvents.count):\($0.recentAssistantMessages.count)"
            }
            .joined(separator: "|")
        return "\(sessions):\(usageService.currentUsage?.usagePercentage ?? -1):\(usageService.error ?? ""):\(AppSettings.isUsageEnabled)"
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                sessionPickerContent(geometry: geometry)
                    .opacity(!showingSettings && shouldShowSessionPicker ? 1 : 0)
                    .allowsHitTesting(!showingSettings && shouldShowSessionPicker)
                    .disabled(showingSettings || !shouldShowSessionPicker)
                    .accessibilityHidden(showingSettings || !shouldShowSessionPicker)

                activityContent(geometry: geometry)
                    .opacity(!showingSettings && !shouldShowSessionPicker ? 1 : 0)
                    .allowsHitTesting(!showingSettings && !shouldShowSessionPicker)
                    .disabled(showingSettings || shouldShowSessionPicker)
                    .accessibilityHidden(showingSettings || shouldShowSessionPicker)

                PanelSettingsView()
                    .frame(width: geometry.size.width)
                    .offset(x: showingSettings ? 0 : geometry.size.width)
                    .opacity(showingSettings ? 1 : 0)
                    .allowsHitTesting(showingSettings)
                    .disabled(!showingSettings)
                    .accessibilityHidden(!showingSettings)
            }
        }
        .task(id: usageRefreshTrigger) {
            await localUsageService.refreshAll()
        }
    }

    @ViewBuilder
    private func sessionPickerContent(geometry: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if isActivityCollapsed {
                Spacer()
                    .allowsHitTesting(false)
            } else {
                Spacer()
                    .frame(height: geometry.size.height * 0.4 + topVisualClearance)
                    .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 0) {
                if !isActivityCollapsed {
                    Divider().background(Color.white.opacity(0.08))

                    SessionListView(
                        sessions: sessionStore.sortedSessions,
                        selectedSessionId: sessionStore.selectedSessionId,
                        onSelectSession: { sessionId in
                            sessionStore.selectSession(sessionId)
                            showingSessionActivity = true
                        },
                        onDeleteSession: { sessionId in
                            sessionStore.dismissSession(sessionId)
                        }
                    )
                }

                Spacer()

                usageFooter(compact: false)
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func activityContent(geometry: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if isActivityCollapsed {
                Spacer()
                    .allowsHitTesting(false)
            } else {
                Spacer()
                    .frame(height: geometry.size.height * 0.4 + topVisualClearance)
                    .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 0) {
                if hasActivity {
                    Divider().background(Color.white.opacity(0.08))
                    activitySection
                } else if !isActivityCollapsed {
                    Spacer()
                    emptyState
                }

                if !isActivityCollapsed {
                    Spacer()
                }

                if showIndicator && !isActivityCollapsed {
                    WorkingIndicatorView(
                        state: state,
                        source: effectiveSession?.source
                    )
                }

                usageFooter(compact: isActivityCollapsed)
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isActivityCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        if let session = effectiveSession {
                            Text("\(session.projectName) #\(session.sessionNumber)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(TerminalColors.secondaryText)
                        }

                        Spacer()

                        if let mode = effectiveSession?.currentModeDisplay {
                            ModeBadgeView(mode: mode)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 0) {
                                if let prompt = effectiveSession?.lastUserPrompt {
                                    UserPromptBubbleView(text: prompt)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                        .padding(.bottom, 8)
                                }

                                ForEach(unifiedActivityItems) { item in
                                    switch item {
                                    case .tool(let event):
                                        ActivityRowView(event: event)
                                            .id(item.id)
                                    case .assistant(let message):
                                        AssistantTextRowView(message: message)
                                            .id(item.id)
                                    }
                                }

                                let questions = effectiveSession?.pendingQuestions ?? []
                                if !questions.isEmpty {
                                    QuestionPromptView(questions: questions)
                                        .id("question-prompt")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                        .onAppear {
                            if let lastItem = unifiedActivityItems.last {
                                proxy.scrollTo(lastItem.id, anchor: .bottom)
                            }
                        }
                        .onChange(of: unifiedActivityItems.last?.id) { _, newId in
                            if let id = newId {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(id, anchor: .bottom)
                                }
                            }
                        }
                        .onChange(of: effectiveSession?.pendingQuestions.isEmpty) { _, isEmpty in
                            if isEmpty == false {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("question-prompt", anchor: .bottom)
                                }
                            }
                        }
                    }

                }
                .transition(.opacity)
            }
        }
    }

    private var emptyState: some View {
        let hooksInstalled = HookInstallerCoordinator.isAnyInstalled()
        let title = hooksInstalled ? "Waiting for activity" : "Hooks not installed"
        let subtitle = hooksInstalled
            ? "Send a message in any connected CLI to start tracking"
            : "Open settings to install hooks for your CLI"

        return VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(TerminalColors.secondaryText)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(TerminalColors.dimmedText)
        }
        .frame(maxWidth: .infinity)
    }

    private func usageFooter(compact: Bool) -> some View {
        MultiUsageBarsView(
            claudeUsage: usageService.currentUsage,
            claudeLoading: usageService.isLoading,
            claudeError: usageService.error,
            claudeEnabled: AppSettings.isUsageEnabled,
            codexUsage: localUsageService.codexUsage,
            geminiUsage: localUsageService.geminiUsage,
            localLoading: localUsageService.isLoading,
            compact: compact,
            onClaudeConnect: { ClaudeUsageService.shared.connectAndStartPolling() },
            onClaudeRetry: { ClaudeUsageService.shared.retryNow() }
        )
    }
}

struct PanelHeaderButton: View {
    let sfSymbol: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: sfSymbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 32, height: 32)
                .background(isHovered ? TerminalColors.hoverBackground : TerminalColors.subtleBackground)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct ModeBadgeView: View {
    let mode: String

    var color: Color {
        switch mode {
        case "Plan Mode": TerminalColors.planMode
        case "Accept Edits": TerminalColors.acceptEdits
        default: TerminalColors.secondaryText
        }
    }

    var body: some View {
        Text(mode)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(color)
    }
}
