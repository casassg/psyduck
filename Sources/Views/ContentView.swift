import SwiftUI

struct ContentView: View {
    @State private var viewModel = BoardViewModel()

    var body: some View {
        ZStack {
            Theme.windowBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                toolbarArea
                Divider().opacity(0.15)

                if viewModel.isLoading && viewModel.pullRequests.isEmpty {
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
        .onChange(of: viewModel.selectedOrg) {
            if let repo = viewModel.selectedRepo,
                !viewModel.repositories.contains(repo)
            {
                viewModel.selectedRepo = nil
            }
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
        // Confirmation dialog for merge/close/delete
        .alert(
            confirmationTitle,
            isPresented: showConfirmation,
            actions: { confirmationActions },
            message: { Text(confirmationMessage) }
        )
        // Error alert after failed action
        .alert(
            "Action Failed",
            isPresented: showActionError,
            actions: {
                // If this is a force-delete prompt, show force option
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
            // Safe to clear here — button closures capture the action synchronously
            // before this setter fires, so executeAction() uses the captured copy.
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
            // Capture action synchronously — by the time the Task body runs,
            // the alert dismiss may have already cleared pendingAction.
            switch action {
            case .merge:
                Button("Merge", role: .destructive) {
                    Task { await viewModel.executeAction(action) }
                }
            case .close:
                Button("Close PR", role: .destructive) {
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
            Text("Pull Requests")
                .font(Theme.toolbarTitleFont)
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            filterGroup

            Spacer()

            refreshArea

            // Settings gear
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

    @ViewBuilder
    private var filterGroup: some View {
        HStack(spacing: 8) {
            filterPicker(
                title: "Organization",
                selection: $viewModel.selectedOrg,
                options: viewModel.organizations,
                displayName: { $0 }
            )

            filterPicker(
                title: "Repository",
                selection: $viewModel.selectedRepo,
                options: viewModel.repositories,
                displayName: { name in
                    if viewModel.selectedOrg != nil {
                        return name.split(separator: "/").last.map(String.init) ?? name
                    }
                    return name
                }
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

    private func filterPicker(
        title: String,
        selection: Binding<String?>,
        options: [String],
        displayName: @escaping (String) -> String
    ) -> some View {
        Menu {
            Button("All \(title)s") {
                withAnimation(.snappy(duration: 0.25)) {
                    selection.wrappedValue = nil
                }
            }
            Divider()
            ForEach(options, id: \.self) { option in
                Button(displayName(option)) {
                    withAnimation(.snappy(duration: 0.25)) {
                        selection.wrappedValue = option
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selection.wrappedValue.map(displayName) ?? "All \(title)s")
                    .font(Theme.filterFont)
                    .foregroundStyle(
                        selection.wrappedValue != nil ? Theme.textPrimary : Theme.textSecondary
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
