import SwiftUI

struct ContentView: View {
    @State private var viewModel = BoardViewModel()

    var body: some View {
        ZStack {
            Theme.windowBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                toolbarArea
                Divider().opacity(0.15)

                if viewModel.setupStatus != .ok {
                    setupErrorView
                } else if viewModel.isLoading && viewModel.pullRequests.isEmpty {
                    loadingView
                } else if let error = viewModel.errorMessage, viewModel.pullRequests.isEmpty {
                    errorView(error)
                } else {
                    ZStack(alignment: .top) {
                        KanbanBoard(viewModel: viewModel)

                        if let error = viewModel.errorMessage {
                            errorBanner(error)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                }
            }
        }
        .background {
            Button("") { Task { await viewModel.refresh() } }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
        }
        .task {
            await viewModel.refresh()
            viewModel.startAutoRefresh()
        }
        .onDisappear {
            viewModel.stopAutoRefresh()
        }
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsSheet(viewModel: viewModel)
        }
        .alert(
            confirmationTitle,
            isPresented: showConfirmation,
            actions: { confirmationActions },
            message: { Text(confirmationMessage) }
        )
        .alert(
            "Action Failed",
            isPresented: showActionError,
            actions: {
                if let action = viewModel.pendingAction, case .deleteWorktree = action {
                    Button("Force Delete", role: .destructive) {
                        Task { await viewModel.executeAction(action) }
                    }
                    Button("Cancel", role: .cancel) {
                        viewModel.dismissAction()
                        viewModel.actionError = nil
                    }
                } else {
                    Button("OK") { viewModel.actionError = nil }
                }
            },
            message: { Text(viewModel.actionError ?? "") }
        )
    }

    // MARK: - Confirmation Bindings

    private var showConfirmation: Binding<Bool> {
        Binding(
            get: { viewModel.pendingAction != nil && viewModel.actionError == nil },
            set: { if !$0 { viewModel.pendingAction = nil } }
        )
    }

    private var showActionError: Binding<Bool> {
        Binding(
            get: { viewModel.actionError != nil },
            set: { if !$0 { viewModel.actionError = nil } }
        )
    }

    private var confirmationTitle: String {
        guard let action = viewModel.pendingAction else { return "" }
        switch action {
        case .merge: return "Merge Pull Request?"
        case .close: return "Close Pull Request?"
        case .publish: return "Ready for Review?"
        case .updateBranch: return "Update Branch?"
        case .deleteWorktree: return "Delete Worktree?"
        }
    }

    private var confirmationMessage: String {
        guard let action = viewModel.pendingAction else { return "" }
        switch action {
        case .merge(let pr, let strategy):
            return "\(strategy.rawValue) #\(pr.number) into base branch.\nThe remote branch will be deleted."
        case .close(let pr):
            return "Close #\(pr.number) (\(pr.title)).\nThe remote branch will be deleted."
        case .publish(let pr):
            return "Mark #\(pr.number) (\(pr.title)) as ready for review."
        case .updateBranch(let pr):
            return "Rebase #\(pr.number) on top of the latest base branch."
        case .deleteWorktree(let pr, let force):
            let path = pr.worktree?.displayPath ?? "?"
            let forceNote = force ? " (force — uncommitted changes will be lost)" : ""
            return "Remove worktree at \(path)\(forceNote)"
        }
    }

    @ViewBuilder
    private var confirmationActions: some View {
        if let action = viewModel.pendingAction {
            switch action {
            case .merge:
                Button("Merge", role: .destructive) {
                    Task { await viewModel.executeAction(action) }
                }
            case .close:
                Button("Close PR", role: .destructive) {
                    Task { await viewModel.executeAction(action) }
                }
            case .publish:
                Button("Publish") {
                    Task { await viewModel.executeAction(action) }
                }
            case .updateBranch:
                Button("Update") {
                    Task { await viewModel.executeAction(action) }
                }
            case .deleteWorktree:
                Button("Delete", role: .destructive) {
                    Task { await viewModel.executeAction(action) }
                }
            }
            Button("Cancel", role: .cancel) { viewModel.dismissAction() }
        }
    }

    // MARK: - Toolbar

    private var toolbarArea: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                if let logoURL = Bundle.module.url(forResource: "logo", withExtension: "png"),
                    let nsImage = NSImage(contentsOf: logoURL)
                {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text("PsyDuck")
                    .font(Theme.toolbarTitleFont)
                    .foregroundStyle(Theme.textPrimary)
            }

            Spacer()

            filterGroup

            Spacer()

            refreshArea

            Button { viewModel.showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Theme.surfaceBackground, in: Circle())
                    .overlay(Circle().stroke(Theme.cardBorder, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .pointingHand()
            .help("Settings — tracked folders")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.windowBackground)
    }

    // MARK: - Multi-Select Filters

    @ViewBuilder
    private var filterGroup: some View {
        HStack(spacing: 8) {
            multiFilterPicker(
                title: "Organization",
                selected: viewModel.selectedOrgs,
                options: viewModel.organizations,
                displayName: { $0 },
                toggle: { viewModel.toggleOrg($0) }
            )

            multiFilterPicker(
                title: "Repository",
                selected: viewModel.selectedRepos,
                options: viewModel.repositories,
                displayName: { name in
                    if !viewModel.selectedOrgs.isEmpty {
                        return name.split(separator: "/").last.map(String.init) ?? name
                    }
                    return name
                },
                toggle: { viewModel.toggleRepo($0) }
            )

            if viewModel.hasActiveFilters {
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        viewModel.clearFilters()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .pointingHand()
                .help("Clear all filters")
            }
        }
    }

    private func multiFilterPicker(
        title: String,
        selected: Set<String>,
        options: [String],
        displayName: @escaping (String) -> String,
        toggle: @escaping (String) -> Void
    ) -> some View {
        let pillLabel: String = {
            if selected.isEmpty { return "All \(title)s" }
            if selected.count == 1 { return displayName(selected.first!) }
            return "\(selected.count) \(title)s"
        }()

        return Menu {
            if !selected.isEmpty {
                Button("Clear \(title)s") {
                    withAnimation(.snappy(duration: 0.25)) {
                        for item in selected { toggle(item) }
                    }
                }
                Divider()
            }
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        toggle(option)
                    }
                } label: {
                    HStack {
                        Text(displayName(option))
                        Spacer()
                        if selected.contains(option) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(pillLabel)
                    .font(Theme.filterFont)
                    .foregroundStyle(
                        selected.isEmpty ? Theme.textSecondary : Theme.textPrimary
                    )
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.surfaceBackground, in: Capsule())
            .overlay(Capsule().stroke(Theme.cardBorder, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .pointingHand()
    }

    private var refreshArea: some View {
        HStack(spacing: 10) {
            if !viewModel.lastRefreshText.isEmpty {
                Text(viewModel.lastRefreshText)
                    .font(Theme.metaFont)
                    .foregroundStyle(Theme.textTertiary)
            }

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Group {
                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(Theme.surfaceBackground, in: Circle())
                .overlay(Circle().stroke(Theme.cardBorder, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .pointingHand()
            .disabled(viewModel.isLoading)
            .help("Refresh (auto-refreshes every 5m)")
        }
    }

    // MARK: - States

    private var setupErrorView: some View {
        VStack(spacing: 16) {
            Spacer()

            if let logoURL = Bundle.module.url(forResource: "logo", withExtension: "png"),
                let nsImage = NSImage(contentsOf: logoURL)
            {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if viewModel.setupStatus == .ghNotInstalled {
                Text("GitHub CLI not found")
                    .font(Theme.toolbarTitleFont)
                    .foregroundStyle(Theme.textPrimary)
                Text("PsyDuck requires the **gh** CLI to fetch your pull requests.")
                    .font(Theme.filterFont)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                Text("Install it with Homebrew:")
                    .font(Theme.metaFont)
                    .foregroundStyle(Theme.textTertiary)
                Text("brew install gh")
                    .font(Theme.metaMonoFont)
                    .foregroundStyle(Theme.inReviewAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.surfaceBackground, in: RoundedRectangle(cornerRadius: 8))
                Button("Open cli.github.com") {
                    NSWorkspace.shared.open(URL(string: "https://cli.github.com/")!)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.validationAccent)
                .pointingHand()
            } else {
                Text("GitHub CLI not authenticated")
                    .font(Theme.toolbarTitleFont)
                    .foregroundStyle(Theme.textPrimary)
                Text("PsyDuck needs **gh** to be logged in to fetch your pull requests.")
                    .font(Theme.filterFont)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                Text("Run this in your terminal:")
                    .font(Theme.metaFont)
                    .foregroundStyle(Theme.textTertiary)
                Text("gh auth login")
                    .font(Theme.metaMonoFont)
                    .foregroundStyle(Theme.inReviewAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.surfaceBackground, in: RoundedRectangle(cornerRadius: 8))
            }

            Button("Retry") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.approvedAccent)
            .pointingHand()
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .scaleEffect(0.8)
            Text("Loading pull requests...")
                .font(Theme.filterFont)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(Theme.inReviewAccent)
            Text("Failed to load PRs")
                .font(Theme.toolbarTitleFont)
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(Theme.metaFont)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Retry") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.inReviewAccent)
            .pointingHand()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.inReviewAccent)
            Text(message)
                .font(Theme.metaFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer()
            Button("Dismiss") {
                withAnimation { viewModel.errorMessage = nil }
            }
            .font(Theme.metaFont)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .pointingHand()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(hex: 0xFF9F0A, opacity: 0.15), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.inReviewAccent.opacity(0.3), lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}
