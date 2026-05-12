import SwiftUI

struct TaskCard: View {
    let task: BoardTask
    let accentColor: Color
    let viewModel: BoardViewModel
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var showPlanPicker = false

    private var isAgentRunning: Bool {
        viewModel.isAgentRunning(for: task.id)
    }

    private var taskColumn: KanbanColumn {
        viewModel.column(for: task) ?? .triage
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            cardContent

            if isHovered && taskColumn == .triage {
                Button { onDelete() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 18, height: 18)
                        .background(Theme.surfaceBackground, in: Circle())
                        .overlay(Circle().stroke(Theme.cardBorder, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .pointingHand()
                .help("Remove task")
                .padding(6)
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.15), value: isHovered)
        .onHover { hovering in isHovered = hovering }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Identifier + priority
            HStack(spacing: 6) {
                Text(task.displayIdentifier)
                    .font(Theme.repoFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)

                Spacer()

                if let priority = task.priority {
                    Text(priority.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(priority.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(priority.color.opacity(0.12), in: Capsule())
                }
            }

            // Title — click opens detail view
            Text(task.title)
                .font(Theme.titleFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .pointingHand()
                .onTapGesture {
                    viewModel.selectedTask = task
                }

            // Labels
            if !task.labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(task.labels.prefix(3), id: \.self) { label in
                        Text(label)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.surfaceBackground, in: Capsule())
                    }
                    if task.labels.count > 3 {
                        Text("+\(task.labels.count - 3)")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }

            // Status badge
            statusBadge

            Spacer().frame(height: 2)

            // Meta row
            HStack(spacing: 0) {
                Text(relativeTime(task.updatedAt))
                    .font(Theme.metaFont)
                    .foregroundStyle(Theme.textTertiary)

                Spacer()

                if task.linearId != nil {
                    Image(systemName: "link")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                        .help("Synced from Linear")
                }

                if !task.comments.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 9))
                        Text("\(task.comments.count)")
                            .font(Theme.metaMonoFont)
                    }
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 8)
                }
            }

            // Action buttons
            actionRow
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .fill(isHovered ? Theme.cardBackgroundHover : Theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .stroke(
                    isHovered ? accentColor.opacity(0.3) : Theme.cardBorder,
                    lineWidth: 0.5
                )
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
    }

    // MARK: - Status Badge

    @ViewBuilder
    private var statusBadge: some View {
        if isAgentRunning {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini).scaleEffect(0.6)
                    Text(viewModel.agentMode(for: task.id) == .planning ? "Planning..." : "Building...")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(Theme.buildAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.buildAccent.opacity(0.12), in: Capsule())
                .pointingHand()
                .onTapGesture { viewModel.selectedTask = task }

                Button { viewModel.cancelAgent(id: task.id) } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.diffDeletion)
                        .frame(width: 20, height: 20)
                        .background(Theme.diffDeletion.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .pointingHand()
                .help("Stop agent")
            }
        } else if taskColumn == .plan, let planStatus = task.planStatus {
            planStatusBadge(planStatus)
        } else if taskColumn == .build {
            HStack(spacing: 5) {
                Image(systemName: "hammer")
                    .font(.system(size: 9))
                Text("Build")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(Theme.buildAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.buildAccent.opacity(0.12), in: Capsule())
        }
    }

    @ViewBuilder
    private func planStatusBadge(_ status: PlanStatus) -> some View {
        let (icon, label, color): (String, String, Color) = {
            switch status {
            case .readyForReview: return ("checkmark.circle", "Ready for review", Theme.approvedAccent)
            case .revising: return ("arrow.clockwise", "Revising...", Theme.inReviewAccent)
            }
        }()

        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Action Row

    @ViewBuilder
    private var actionRow: some View {
        // Triage: Plan button with agent picker
        if taskColumn == .triage {
            Divider().opacity(0.1).padding(.vertical, 2)
            HStack(spacing: 6) {
                // Open detail
                Button { viewModel.selectedTask = task } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                        Text("Details")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.surfaceBackground, in: Capsule())
                    .overlay(Capsule().stroke(Theme.cardBorder, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .pointingHand()

                Spacer()

                Button { showPlanPicker = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 10))
                        Text("Plan")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.planAccent.opacity(0.8), in: Capsule())
                }
                .buttonStyle(.plain)
                .pointingHand()
                .popover(isPresented: $showPlanPicker) {
                    AgentPickerPopover(
                        title: "Start Planning",
                        viewModel: viewModel,
                        defaultAgentId: viewModel.agentPreferences.defaultPlanningAgentId,
                        showRepos: true,
                        onStart: { agentId, model, variant, repos in
                            showPlanPicker = false
                            Task {
                                await viewModel.startPlanning(
                                    task: task, agentId: agentId, model: model,
                                    variant: variant, repos: repos
                                )
                                viewModel.selectedTask = viewModel.tasks.first { $0.id == task.id }
                            }
                        }
                    )
                }
            }
        }

        // Plan/Build: View details button
        if taskColumn == .plan || taskColumn == .build {
            Divider().opacity(0.1).padding(.vertical, 2)
            HStack(spacing: 6) {
                Button { viewModel.selectedTask = task } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isAgentRunning ? "eye" : "info.circle")
                            .font(.system(size: 10))
                        Text(isAgentRunning ? "View Agent" : "Details")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(isAgentRunning ? Theme.buildAccent : Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        (isAgentRunning ? Theme.buildAccent : Theme.surfaceBackground).opacity(isAgentRunning ? 0.15 : 1),
                        in: Capsule()
                    )
                    .overlay(Capsule().stroke(
                        isAgentRunning ? Theme.buildAccent.opacity(0.3) : Theme.cardBorder,
                        lineWidth: 0.5
                    ))
                }
                .buttonStyle(.plain)
                .pointingHand()

                Spacer()

                // Review Plan button (when ready)
                if taskColumn == .plan, task.planStatus == .readyForReview {
                    Button {
                        viewModel.showPlanReview = task
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 10))
                            Text("Review Plan")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.approvedAccent.opacity(0.8), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointingHand()
                }
            }
        }
    }
}

// MARK: - Agent Picker Popover

struct AgentPickerPopover: View {
    let title: String
    let viewModel: BoardViewModel
    let defaultAgentId: String?
    let showRepos: Bool
    /// (agentId, model, variant, selectedRepos)
    let onStart: (String, String?, String?, [String]) -> Void

    @State private var selectedAgentId: String = ""
    @State private var selectedModel: String = ""
    @State private var selectedVariant: String = ""
    @State private var selectedRepos: Set<String> = []

    private var currentAgent: AgentConfig? {
        viewModel.agentPreferences.agents.first { $0.id == selectedAgentId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Theme.filterFont)
                .foregroundStyle(Theme.textPrimary)

            // Agent picker
            VStack(alignment: .leading, spacing: 3) {
                Text("Agent")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                Picker("", selection: $selectedAgentId) {
                    ForEach(viewModel.agentPreferences.agents.filter(\.isAvailable)) { agent in
                        Text(agent.displayName).tag(agent.id)
                    }
                }
                .labelsHidden()
                .onChange(of: selectedAgentId) { _, newId in
                    if let agent = viewModel.agentPreferences.agents.first(where: { $0.id == newId }) {
                        selectedModel = agent.defaultModel ?? ""
                        selectedVariant = agent.defaultVariant ?? ""
                    }
                }
            }

            // Model picker — dropdown if models discovered, text field otherwise
            VStack(alignment: .leading, spacing: 3) {
                Text("Model")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)

                if let models = currentAgent?.availableModels, !models.isEmpty {
                    Picker("", selection: $selectedModel) {
                        Text("Default").tag("")
                        ForEach(models, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                } else {
                    TextField("provider/model", text: $selectedModel)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.metaMonoFont)
                }
            }

            // Variant picker — show only if agent has variants
            if let variants = currentAgent?.availableVariants, !variants.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Variant")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                    Picker("", selection: $selectedVariant) {
                        Text("Default").tag("")
                        ForEach(variants, id: \.self) { v in
                            Text(v).tag(v)
                        }
                    }
                    .labelsHidden()
                }
            }

            // Repo selection — filtered by current org/repo pills
            if showRepos {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Repos")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)

                    let repos = viewModel.filteredRepoNames()
                    if repos.isEmpty {
                        Text("No repos found. Add tracked folders in Settings.")
                            .font(Theme.metaFont)
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(repos, id: \.self) { repo in
                                    Button {
                                        if selectedRepos.contains(repo) {
                                            selectedRepos.remove(repo)
                                        } else {
                                            selectedRepos.insert(repo)
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: selectedRepos.contains(repo) ? "checkmark.square.fill" : "square")
                                                .font(.system(size: 11))
                                                .foregroundStyle(selectedRepos.contains(repo) ? Theme.approvedAccent : Theme.textTertiary)
                                            Text(repo)
                                                .font(Theme.metaMonoFont)
                                                .foregroundStyle(Theme.textPrimary)
                                                .lineLimit(1)
                                            Spacer()
                                        }
                                        .padding(.vertical, 3)
                                        .padding(.horizontal, 6)
                                        .background(
                                            selectedRepos.contains(repo) ? Theme.approvedAccent.opacity(0.08) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 4)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .pointingHand()
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                }
            }

            Button {
                let model = selectedModel.isEmpty ? nil : selectedModel
                let variant = selectedVariant.isEmpty ? nil : selectedVariant
                onStart(selectedAgentId, model, variant, Array(selectedRepos))
            } label: {
                Text("Start")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Theme.planAccent.opacity(0.8), in: Capsule())
            }
            .buttonStyle(.plain)
            .pointingHand()
            .disabled(selectedAgentId.isEmpty)
        }
        .padding(12)
        .frame(width: 280)
        .background(Theme.windowBackground)
        .onAppear {
            selectedAgentId = defaultAgentId ?? viewModel.agentPreferences.agents.first(where: \.isAvailable)?.id ?? ""
            if let agent = viewModel.agentPreferences.agents.first(where: { $0.id == selectedAgentId }) {
                selectedModel = agent.defaultModel ?? ""
                selectedVariant = agent.defaultVariant ?? ""
            }
            // Pre-select all filtered repos
            if showRepos {
                selectedRepos = Set(viewModel.filteredRepoNames())
            }
        }
    }
}

private func relativeTime(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}
