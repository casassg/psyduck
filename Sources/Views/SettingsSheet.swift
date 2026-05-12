import SwiftUI

struct SettingsSheet: View {
    @Bindable var viewModel: BoardViewModel
    @State private var selectedTab = "folders"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(Theme.toolbarTitleFont)
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                Button {
                    viewModel.showSettings = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .pointingHand()
            }
            .padding(20)

            Divider().opacity(0.15)

            // Tab bar
            HStack(spacing: 0) {
                tabButton("Folders", tab: "folders", icon: "folder")
                tabButton("Linear", tab: "linear", icon: "link")
                tabButton("Agents", tab: "agents", icon: "cpu")
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider().opacity(0.15)

            // Tab content
            switch selectedTab {
            case "folders": foldersTab
            case "linear": linearTab
            case "agents": agentsTab
            default: foldersTab
            }
        }
        .frame(minWidth: 520, maxWidth: 520, minHeight: 400, maxHeight: 600)
        .background(Theme.windowBackground)
    }

    private func tabButton(_ title: String, tab: String, icon: String) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) { selectedTab = tab }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(Theme.filterFont)
            }
            .foregroundStyle(selectedTab == tab ? Theme.textPrimary : Theme.textTertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                selectedTab == tab ? Theme.surfaceBackground : Color.clear,
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(
                    selectedTab == tab ? Theme.cardBorder : Color.clear,
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
        .pointingHand()
    }

    // MARK: - Folders Tab

    private var foldersTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(
                "Add folders that contain your main git checkouts (e.g. ~/Development). All worktrees are discovered automatically."
            )
            .font(Theme.metaFont)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if viewModel.trackedFolders.isEmpty {
                emptyFolderState
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(viewModel.trackedFolders, id: \.self) { folder in
                            folderRow(folder)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            }

            Divider().opacity(0.15)

            HStack {
                Spacer()
                Button { pickFolder() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Add Folder")
                            .font(Theme.filterFont)
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.surfaceBackground, in: Capsule())
                    .overlay(Capsule().stroke(Theme.cardBorder, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .pointingHand()
                Spacer()
            }
            .padding(16)
        }
    }

    // MARK: - Linear Tab

    private var linearTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to Linear to sync your tickets into the Triage column.")
                .font(Theme.metaFont)
                .foregroundStyle(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Personal API Key")
                    .font(Theme.filterFont)
                    .foregroundStyle(Theme.textPrimary)

                SecureField("lin_api_...", text: $viewModel.linearApiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.metaMonoFont)

                Text("Generate at Settings → API → Personal API keys in Linear.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)

                Button("Open Linear API Settings") {
                    NSWorkspace.shared.open(URL(string: "https://linear.app/settings/account/security")!)
                }
                .font(Theme.metaFont)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.validationAccent)
                .pointingHand()
            }

            if !viewModel.linearApiKey.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.approvedAccent)
                        .font(.system(size: 12))
                    Text("API key configured. Tickets will sync on next refresh.")
                        .font(Theme.metaFont)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer()
        }
        .padding(20)
    }

    // MARK: - Agents Tab

    private var agentsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configure coding agents for the Plan and Build phases.")
                .font(Theme.metaFont)
                .foregroundStyle(Theme.textSecondary)

            // Default agent pickers
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Default Planning Agent")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                    agentPicker(selection: Binding(
                        get: { viewModel.agentPreferences.defaultPlanningAgentId },
                        set: { viewModel.agentPreferences.defaultPlanningAgentId = $0 }
                    ))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Default Building Agent")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                    agentPicker(selection: Binding(
                        get: { viewModel.agentPreferences.defaultBuildingAgentId },
                        set: { viewModel.agentPreferences.defaultBuildingAgentId = $0 }
                    ))
                }
            }

            Divider().opacity(0.15)

            // Agent list with model config
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(
                        Array(viewModel.agentPreferences.agents.enumerated()), id: \.element.id
                    ) { index, agent in
                        agentRow(agent: agent, index: index)
                    }
                }
            }

            Spacer()
        }
        .padding(20)
    }

    private func agentPicker(selection: Binding<String?>) -> some View {
        let available = viewModel.agentPreferences.agents
        return Picker("", selection: selection) {
            Text("None").tag(String?.none)
            ForEach(available) { agent in
                Text(agent.displayName).tag(Optional(agent.id))
            }
        }
        .labelsHidden()
        .frame(maxWidth: 180)
    }

    private func agentRow(agent: AgentConfig, index: Int) -> some View {
        HStack(spacing: 10) {
            // Status dot
            Circle()
                .fill(agent.isAvailable ? Theme.approvedAccent : Theme.textTertiary)
                .frame(width: 6, height: 6)
                .help(agent.isAvailable ? "Available on PATH" : "Not found on PATH")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.displayName)
                        .font(Theme.filterFont)
                        .foregroundStyle(Theme.textPrimary)
                    if agent.acpNative {
                        Text("ACP")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.validationAccent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.validationAccent.opacity(0.15), in: Capsule())
                    }
                }
                Text(agent.command)
                    .font(Theme.metaMonoFont)
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer()

            // Model — dropdown if models discovered, text field otherwise
            if let models = agent.availableModels, !models.isEmpty {
                Picker("", selection: Binding(
                    get: { agent.defaultModel ?? "" },
                    set: { viewModel.agentPreferences.agents[index].defaultModel = $0.isEmpty ? nil : $0 }
                )) {
                    Text("—").tag("")
                    ForEach(models, id: \.self) { m in Text(m).tag(m) }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
                .help("Default model")
            } else {
                TextField("model", text: Binding(
                    get: { agent.defaultModel ?? "" },
                    set: { viewModel.agentPreferences.agents[index].defaultModel = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(Theme.metaMonoFont)
                .frame(maxWidth: 120)
                .help("Default model for this agent")
            }

            // Variant — dropdown if variants available
            if let variants = agent.availableVariants, !variants.isEmpty {
                Picker("", selection: Binding(
                    get: { agent.defaultVariant ?? "" },
                    set: { viewModel.agentPreferences.agents[index].defaultVariant = $0.isEmpty ? nil : $0 }
                )) {
                    Text("—").tag("")
                    ForEach(variants, id: \.self) { v in Text(v).tag(v) }
                }
                .labelsHidden()
                .frame(maxWidth: 80)
                .help("Default variant")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Folder Helpers

    private func folderRow(_ folder: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inReviewAccent)

            Text(abbreviatePath(folder))
                .font(Theme.repoFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    viewModel.removeTrackedFolder(folder)
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.diffDeletion.opacity(0.7))
            }
            .buttonStyle(.plain)
            .pointingHand()
            .help("Remove folder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyFolderState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 28))
                .foregroundStyle(Theme.textTertiary)
            Text("No folders tracked yet")
                .font(Theme.filterFont)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing your git repositories"
        panel.prompt = "Track Folder"
        let devPath = (NSHomeDirectory() as NSString).appendingPathComponent("Development")
        if FileManager.default.fileExists(atPath: devPath) {
            panel.directoryURL = URL(fileURLWithPath: devPath)
        }

        if panel.runModal() == .OK, let url = panel.url {
            withAnimation(.snappy(duration: 0.2)) {
                viewModel.addTrackedFolder(url.path)
            }
        }
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
