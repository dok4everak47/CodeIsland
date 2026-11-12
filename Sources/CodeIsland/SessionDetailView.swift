import SwiftUI
import CodeIslandCore

/// One session's details, in place of the session list.
///
/// A click on a card used to *be* the jump to its terminal: it took the user
/// out of whatever they were doing for what is usually a glance. This page
/// keeps the glance in the island and answers, top to bottom, the four things
/// they look for:
///
/// 1. which session this is — status, project, branch, model, how long
/// 2. what they asked for — the last prompt
/// 3. how far it got — the agent's own checklist and its recent tool calls
/// 4. what it said — the latest reply, as Markdown
///
/// The footer holds only what needs the user now (allow / deny / answer) plus
/// an explicit "open in terminal". Jumping is a button here, not a side
/// effect of clicking the card.
struct SessionDetailView: View {
    var appState: AppState
    let sessionId: String

    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize
    @AppStorage(SettingsKey.maxVisibleSessions) private var maxVisibleSessions = SettingsDefaults.maxVisibleSessions
    @AppStorage(SettingsKey.showModelLabel) private var showModelLabel = SettingsDefaults.showModelLabel

    private var fontSize: CGFloat { CGFloat(contentFontSize) }
    private var session: SessionSnapshot? { appState.sessions[sessionId] }
    private var l10n: L10n { L10n.shared }

    /// The window is sized for `maxVisibleSessions` cards plus the notch bar.
    /// The page's header and footer are fixed, so the scrolling middle gets
    /// what is left — overshooting here clips the footer off the bottom.
    ///
    /// Capped: the window never grows past the screen, so "unlimited" (99)
    /// would otherwise ask for a scroll area taller than any display and put
    /// the footer out of reach.
    private var scrollMaxHeight: CGFloat {
        min(max(120, SessionListMetrics.scrollHeight(maxVisibleSessions: maxVisibleSessions) - 70), 560)
    }

    var body: some View {
        if let session {
            VStack(spacing: 0) {
                header(session)
                    .padding(.horizontal, 14)
                    .padding(.top, 7)
                    .padding(.bottom, 7)
                hairline
                ThinScrollView(maxHeight: scrollMaxHeight) {
                    VStack(alignment: .leading, spacing: 13) {
                        promptBlock(session)
                        taskBlock(session)
                        replyBlock(session)
                        toolBlock(session)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A long page runs off the bottom of the scroll view with no
                // scrollbar until it is scrolled: fade the last line so the
                // cut reads as "there is more" rather than "the page is broken".
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 16)
                    .allowsHitTesting(false)
                }
                hairline
                footer(session)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }

    /// A small caps label that keeps the four blocks apart without a box.
    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: max(8.5, fontSize - 2.5), weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.42))
            .kerning(0.4)
            .fixedSize()
    }

    // MARK: - Header

    private func header(_ session: SessionSnapshot) -> some View {
        HStack(spacing: 6) {
            SessionStatusChip(
                status: SessionCardStatus(session),
                fontSize: SessionStatusChip.fontSize(content: fontSize)
            )
            SessionIdentityLine(
                session: session,
                sessionId: sessionId,
                projectFontSize: fontSize + 2,
                projectColor: .white.opacity(0.95),
                sessionFontSize: fontSize,
                sessionColor: .white.opacity(0.76),
                dividerColor: .white.opacity(0.28)
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if showModelLabel, let model = session.modelLabel {
                SessionTag(model, color: SessionMetadataStyle.modelTagColor, maxWidth: 120)
                    .help(session.model ?? model)
            }
            SessionTag(elapsedTag(session), color: .white.opacity(0.72))

            DetailCloseButton(help: l10n["session_detail_close"]) {
                withAnimation(NotchAnimation.close) {
                    appState.surface = .sessionList
                }
            }
        }
    }

    /// `⏱ 12m` while it runs, `⏳ 3m` while it is waiting on you — no strings,
    /// and no timer: the tag redraws when the session next reports in.
    private func elapsedTag(_ session: SessionSnapshot) -> String {
        let now = Date()
        switch SessionCardStatus(session) {
        case .needsYou:
            return "⏳ " + SessionDetailFormat.short(now.timeIntervalSince(session.lastActivity))
        default:
            return "⏱ " + SessionDetailFormat.short(now.timeIntervalSince(session.startTime))
        }
    }

    // MARK: - Blocks

    @ViewBuilder
    private func promptBlock(_ session: SessionSnapshot) -> some View {
        if let prompt = session.lastUserPrompt, !prompt.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionLabel(l10n["session_detail_prompt"])
                HStack(alignment: .top, spacing: 5) {
                    Text(SessionGlyph.prompt)
                        .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                        .foregroundStyle(SessionGlyph.promptColor)
                        .frame(width: SessionGlyph.columnWidth(fontSize))
                        .accessibilityLabel(SessionGlyph.promptSpoken)
                    Text(ChatMessageTextFormatter.literalText(prompt))
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(SessionGlyph.promptTextColor)
                        .lineLimit(3)
                        .truncationMode(.tail)
                }
                .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func taskBlock(_ session: SessionSnapshot) -> some View {
        let tasks = session.agentTasks
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    sectionLabel(l10n["session_detail_tasks"])
                    Text("\(tasks.completedCount)/\(tasks.items.count)")
                        .font(.system(size: max(9, fontSize - 1), weight: .bold, design: .monospaced))
                        .foregroundStyle(
                            tasks.isAllCompleted
                                ? AgentTaskProgressView.doneColor
                                : .white.opacity(0.7)
                        )
                    Spacer(minLength: 6)
                    TaskProgressTrack(items: tasks.items)
                        .frame(width: 110, height: 3)
                }
                let shown = tasks.items.prefix(maxListedRows)
                ForEach(Array(shown)) { item in
                    taskRow(item)
                }
                if tasks.items.count > maxListedRows {
                    Text(String(format: l10n["task_progress_more"], tasks.items.count - maxListedRows))
                        .font(.system(size: max(9, fontSize - 1), design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.leading, SessionGlyph.columnWidth(fontSize) + 5)
                }
            }
        }
    }

    /// Rows the checklist shows before it turns into a count; the page
    /// scrolls, but a 40-item plan should not push the reply off the fold.
    private var maxListedRows: Int { 9 }

    private func taskRow(_ item: AgentTaskItem) -> some View {
        let symbol: String
        let color: Color
        switch item.status {
        case .completed:
            symbol = "✓"
            color = AgentTaskProgressView.doneColor
        case .inProgress:
            symbol = "▸"
            color = AgentTaskProgressView.activeColor
        case .pending:
            symbol = "○"
            color = .white.opacity(0.32)
        }
        let text = item.status == .inProgress ? item.progressLabel : item.title
        return HStack(alignment: .top, spacing: 5) {
            Text(symbol)
                .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: SessionGlyph.columnWidth(fontSize))
            Text(text)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(
                    item.status == .completed
                        ? .white.opacity(0.42)
                        : (item.status == .inProgress ? .white.opacity(0.95) : .white.opacity(0.66))
                )
                .strikethrough(item.status == .completed, color: .white.opacity(0.3))
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
    }

    @ViewBuilder
    private func replyBlock(_ session: SessionSnapshot) -> some View {
        if let reply = session.lastAssistantMessage, !reply.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionLabel(l10n["session_detail_reply"])
                AssistantReplyText(
                    text: stripDirectives(reply),
                    fontSize: fontSize,
                    lineLimit: nil
                )
                .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func toolBlock(_ session: SessionSnapshot) -> some View {
        let history = Array(session.toolHistory.suffix(maxToolRows))
        let live = liveTool(session)
        if live != nil || !history.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    sectionLabel(l10n["session_detail_tools"])
                    Spacer(minLength: 6)
                    if session.totalToolCallCount > 0 {
                        Text("\(session.totalToolCallCount)")
                            .font(.system(size: max(9, fontSize - 1), design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                if let live {
                    liveToolRow(session, tool: live)
                }
                ForEach(history.reversed()) { entry in
                    toolRow(entry)
                }
            }
        }
    }

    /// The tool running right now, with what it is working on.
    private func liveToolRow(_ session: SessionSnapshot, tool: String) -> some View {
        HStack(spacing: 5) {
            // Orange while it waits on the user, green while it runs.
            SessionToolChip(
                tool: tool,
                color: SessionCardStatus(session) == .needsYou
                    ? SessionCardStatus.needsYou.color
                    : SessionCardStatus.working.color,
                fontSize: fontSize
            )
            if let desc = session.toolDescription, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    /// Rows of history the page shows; the rest is terminal work anyway.
    private var maxToolRows: Int { 7 }

    /// The tool running right now, only while the session is actually working:
    /// a finished turn keeps its history but has nothing live.
    private func liveTool(_ session: SessionSnapshot) -> String? {
        switch session.status {
        case .running, .processing, .waitingApproval, .waitingQuestion:
            return session.currentTool
        case .idle:
            return nil
        }
    }

    private func toolRow(_ entry: ToolHistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text(entry.success ? "✓" : "✗")
                .font(.system(size: max(9, fontSize - 1), weight: .bold, design: .monospaced))
                .foregroundStyle(entry.success ? AgentTaskProgressView.doneColor : Color(red: 0.92, green: 0.38, blue: 0.38))
                .frame(width: SessionGlyph.columnWidth(fontSize))
            Text(ToolNameDisplay.compact(entry.tool))
                .font(.system(size: max(9, fontSize - 1), weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize()
            if let desc = entry.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: max(9, fontSize - 1), design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(SessionDetailFormat.short(Date().timeIntervalSince(entry.timestamp)))
                .font(.system(size: max(9, fontSize - 1), design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
                .fixedSize()
        }
    }

    // MARK: - Footer

    /// Only the actions that are about *this* session right now. Everything
    /// else is a click away in the terminal, which is now an explicit choice.
    private func footer(_ session: SessionSnapshot) -> some View {
        HStack(spacing: 6) {
            if appState.pendingPermission(forSession: sessionId) != nil {
                SessionInlineButton(
                    title: l10n["allow_once"],
                    style: .primary,
                    fontSize: max(10, fontSize),
                    action: { appState.approvePermission(always: false, expectedSessionId: sessionId) }
                )
                SessionInlineButton(
                    title: l10n["always"],
                    style: .quiet,
                    fontSize: max(10, fontSize),
                    action: { appState.approvePermission(always: true, expectedSessionId: sessionId) }
                )
                SessionInlineButton(
                    title: l10n["deny"],
                    style: .destructive,
                    fontSize: max(10, fontSize),
                    action: { appState.denyPermission(expectedSessionId: sessionId) }
                )
            } else if appState.pendingQuestion(forSession: sessionId) != nil {
                SessionInlineButton(
                    title: l10n["session_detail_answer"],
                    style: .primary,
                    fontSize: max(10, fontSize),
                    action: { appState.openPendingQuestionCard(sessionId: sessionId) }
                )
            }
            Spacer(minLength: 8)
            SessionInlineButton(
                title: "↗ " + l10n["session_detail_open_terminal"],
                style: .link,
                fontSize: max(10, fontSize),
                enabled: session.canJumpFromNotch,
                action: { openInTerminal(session) }
            )
        }
    }

    private func openInTerminal(_ session: SessionSnapshot) {
        TerminalActivator.activate(session: session, sessionId: sessionId)
        withAnimation(NotchAnimation.close) {
            appState.surface = .collapsed
            appState.cancelCompletionQueue()
        }
    }
}

// MARK: - Small pieces

/// The ✕ that folds the page back to the session list.
private struct DetailCloseButton: View {
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("✕")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.55))
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(hovering ? 0.12 : 0))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .accessibilityLabel(help)
    }
}

/// The checklist as one bar: a segment per item, so "2/5" has a shape.
private struct TaskProgressTrack: View {
    let items: [AgentTaskItem]

    var body: some View {
        if items.count <= 24 {
            HStack(spacing: 2) {
                ForEach(items) { item in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color(for: item.status))
                }
            }
        } else {
            GeometryReader { geo in
                let done = Double(items.filter { $0.status == .completed }.count) / Double(max(1, items.count))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.white.opacity(0.14))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(AgentTaskProgressView.doneColor)
                        .frame(width: geo.size.width * done)
                }
            }
        }
    }

    private func color(for status: AgentTaskStatus) -> Color {
        switch status {
        case .completed: return AgentTaskProgressView.doneColor
        case .inProgress: return AgentTaskProgressView.activeColor
        case .pending: return Color.white.opacity(0.14)
        }
    }
}

/// Durations the page prints next to the things it shows.
enum SessionDetailFormat {
    /// `12s` / `3m` / `2h` / `4d` — the same words the cards use, in one place.
    static func short(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}
