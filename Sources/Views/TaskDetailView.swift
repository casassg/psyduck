import SwiftUI

/// Full detail view for a task. Shows task info, agent output in real time,
/// steering, and phase-appropriate actions.
struct TaskDetailView: View {
    let task: BoardTask
    let viewModel: BoardViewModel
    let onDismiss: () -> Void

    private var isAgentRunning: Bool {
        viewModel.isAgentRunning(for: task.id)
    }

    private var taskColumn: KanbanColumn {
        viewModel.column(for: task) ?? .triage
    }

    private var events: [AgentOutputEvent] {
        viewModel.agentOutputs[task.id] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.15)
            HSplitView {
                taskInfoPanel
                    .frame(minWidth: 250, idealWidth: 280, maxWidth: 320)
                agentPanel
                    .frame(minWidth: 400, idealWidth: 500)
            }
        }
        .frame(minWidth: 780, idealWidth: 900, minHeight: 500, idealHeight: 650)
        .background(Theme.windowBackground)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            // Phase badge
            phaseBadge

            VStack(alignment: .leading, spacing: 2) {
                Text(task.displayIdentifier)
                    .font(Theme.repoFont)
                    .foregroundStyle(Theme.textTertiary)
                Text(task.title)
                    .font(Theme.toolbarTitleFont)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }

            Spacer()

            if isAgentRunning {
                Button {
                    viewModel.cancelAgent(id: task.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9))
                        Text("Stop Agent")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Theme.diffDeletion)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.diffDeletion.opacity(0.1), in: Capsule())
                    .overlay(Capsule().stroke(Theme.diffDeletion.opacity(0.3), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .pointingHand()
            }

            Button { onDismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .pointingHand()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var phaseBadge: some View {
        let (label, color): (String, Color) = {
            switch taskColumn {
            case .triage: return ("Triage", Theme.triageAccent)
            case .plan:
                if isAgentRunning { return ("Planning...", Theme.planAccent) }
                if task.planStatus == .readyForReview { return ("Plan Ready", Theme.approvedAccent) }
                if task.planStatus == .revising { return ("Revising...", Theme.inReviewAccent) }
                return ("Plan", Theme.planAccent)
            case .build:
                if isAgentRunning { return ("Building...", Theme.buildAccent) }
                return ("Build", Theme.buildAccent)
            default: return ("Task", Theme.textSecondary)
            }
        }()

        return HStack(spacing: 4) {
            if isAgentRunning {
                ProgressView().controlSize(.mini).scaleEffect(0.6)
            }
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
    }

    // MARK: - Left Panel: Task Info

    private var taskInfoPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Priority + labels
                if task.priority != nil || !task.labels.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        if let priority = task.priority {
                            HStack(spacing: 6) {
                                Text("Priority")
                                    .font(Theme.metaFont)
                                    .foregroundStyle(Theme.textTertiary)
                                Text(priority.label)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(priority.color)
                            }
                        }
                        if !task.labels.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(task.labels, id: \.self) { label in
                                    Text(label)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.textSecondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Theme.surfaceBackground, in: Capsule())
                                }
                            }
                        }
                    }
                }

                // Description
                if let description = task.description, !description.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DESCRIPTION")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .tracking(0.5)
                        Text(description)
                            .font(Theme.metaFont)
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                    }
                }

                // Comments
                if !task.comments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("COMMENTS (\(task.comments.count))")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .tracking(0.5)

                        ForEach(Array(task.comments.enumerated()), id: \.offset) { _, comment in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("@\(comment.author)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Theme.textSecondary)
                                Text(comment.body)
                                    .font(Theme.metaFont)
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(4)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                // Links
                if !task.links.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LINKS")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .tracking(0.5)
                        ForEach(task.links, id: \.self) { link in
                            Text(link)
                                .font(Theme.metaMonoFont)
                                .foregroundStyle(Theme.validationAccent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .pointingHand()
                                .onTapGesture {
                                    if let url = URL(string: link) {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                        }
                    }
                }

                // User context (editable when in triage)
                VStack(alignment: .leading, spacing: 4) {
                    Text("ADDITIONAL CONTEXT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .tracking(0.5)

                    if taskColumn == .triage {
                        TextEditor(text: Binding(
                            get: { task.userContext ?? "" },
                            set: { viewModel.updateTaskContext(task, context: $0) }
                        ))
                        .font(Theme.metaFont)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 60, maxHeight: 120)
                        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Theme.cardBorder, lineWidth: 0.5)
                        )

                        Text("Markdown supported. Included in agent context.")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textTertiary)
                    } else if let ctx = task.userContext, !ctx.isEmpty {
                        Text(ctx)
                            .font(Theme.metaFont)
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                    } else {
                        Text("None")
                            .font(Theme.metaFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                // Worktrees
                if let worktrees = task.worktrees, !worktrees.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WORKTREES")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .tracking(0.5)
                        ForEach(worktrees, id: \.path) { wt in
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(.system(size: 9))
                                Text(wt.repoFullName)
                                    .font(Theme.metaMonoFont)
                            }
                            .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }

                Spacer()
            }
            .padding(16)
        }
        .background(Theme.surfaceBackground.opacity(0.5))
    }

    // MARK: - Right Panel: Agent Activity

    private var agentPanel: some View {
        VStack(spacing: 0) {
            // Agent info bar
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.planAccent)

                if let agentId = viewModel.agentMode(for: task.id) == .planning ? task.planningAgentId : task.buildingAgentId,
                   let agent = viewModel.agentPreferences.agents.first(where: { $0.id == agentId })
                {
                    Text(agent.displayName)
                        .font(Theme.filterFont)
                        .foregroundStyle(Theme.textPrimary)
                } else {
                    Text("No agent")
                        .font(Theme.filterFont)
                        .foregroundStyle(Theme.textTertiary)
                }

                if let model = viewModel.agentMode(for: task.id) == .planning ? task.planningModel : task.buildingModel,
                   !model.isEmpty
                {
                    Text(model)
                        .font(Theme.metaMonoFont)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.surfaceBackground, in: Capsule())
                }

                Spacer()

                if isAgentRunning {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini).scaleEffect(0.6)
                        Text("Running")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Theme.buildAccent)
                } else if !events.isEmpty {
                    Text("Completed")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.approvedAccent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.surfaceBackground.opacity(0.3))

            Divider().opacity(0.1)

            if events.isEmpty && !isAgentRunning {
                // No agent activity yet
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "cpu")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.textTertiary)
                    Text("No agent activity yet")
                        .font(Theme.filterFont)
                        .foregroundStyle(Theme.textTertiary)

                    if taskColumn == .triage {
                        Text("Click \"Plan\" on the card to start planning with an agent.")
                            .font(Theme.metaFont)
                            .foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 250)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                // Agent output
                AgentOutputView(
                    events: events,
                    isRunning: isAgentRunning,
                    onSteer: { msg in viewModel.steerAgent(id: task.id, message: msg) },
                    onCancel: { viewModel.cancelAgent(id: task.id) }
                )
            }

            // Phase-specific actions at bottom
            phaseActions
        }
    }

    @ViewBuilder
    private var phaseActions: some View {
        if taskColumn == .plan, task.planStatus == .readyForReview, !isAgentRunning {
            Divider().opacity(0.1)
            HStack(spacing: 12) {
                Spacer()
                Button {
                    onDismiss()
                    viewModel.showPlanReview = task
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10))
                        Text("Review Plan")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Theme.approvedAccent.opacity(0.8), in: Capsule())
                }
                .buttonStyle(.plain)
                .pointingHand()
            }
            .padding(12)
        }
    }
}
