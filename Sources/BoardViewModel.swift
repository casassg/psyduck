import Foundation
import SwiftUI

@Observable
@MainActor
final class BoardViewModel {
    // MARK: - State

    var pullRequests: [PullRequest] = []
    var isLoading = false
    var errorMessage: String?
    var lastRefresh: Date?

    // Filters
    var selectedOrg: String?
    var selectedRepo: String?

    // Settings
    var showSettings = false
    var trackedFolders: [String] = [] {
        didSet { persistTrackedFolders() }
    }

    // Worktree data
    var availableApps: [OpenInApp] = []

    // Confirmation dialog
    var pendingAction: PRAction?
    var actionError: String?

    // MARK: - Private

    private let ghService = GitHubService()
    private let wtService = WorktreeService()
    private var worktreeMap: [WorktreeService.WorktreeKey: Worktree] = [:]
    private var refreshTimer: Timer?

    private static let trackedFoldersKey = "trackedFolders"

    init() {
        // Restore persisted tracked folders
        trackedFolders =
            UserDefaults.standard.stringArray(forKey: Self.trackedFoldersKey) ?? []
        // Detect installed apps once at launch
        availableApps = OpenInApp.detectInstalled()
    }

    // MARK: - Computed (filtered)

    private var filteredPRs: [PullRequest] {
        pullRequests.filter { pr in
            if let org = selectedOrg, pr.repoOwner != org { return false }
            if let repo = selectedRepo, pr.repoFullName != repo { return false }
            return true
        }
    }

    func prs(for column: KanbanColumn) -> [PullRequest] {
        filteredPRs
            .filter { $0.column == column }
            .filter { column != .merged || $0.worktree != nil }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Filter Options

    var organizations: [String] {
        Array(Set(pullRequests.map(\.repoOwner))).sorted()
    }

    var repositories: [String] {
        let repos = pullRequests.filter { pr in
            if let org = selectedOrg { return pr.repoOwner == org }
            return true
        }
        return Array(Set(repos.map(\.repoFullName))).sorted()
    }

    var hasActiveFilters: Bool {
        selectedOrg != nil || selectedRepo != nil
    }

    func clearFilters() {
        selectedOrg = nil
        selectedRepo = nil
    }

    // MARK: - Tracked Folders

    func addTrackedFolder(_ path: String) {
        guard !trackedFolders.contains(path) else { return }
        trackedFolders.append(path)
    }

    func removeTrackedFolder(at offsets: IndexSet) {
        trackedFolders.remove(atOffsets: offsets)
    }

    func removeTrackedFolder(_ path: String) {
        trackedFolders.removeAll { $0 == path }
    }

    private func persistTrackedFolders() {
        UserDefaults.standard.set(trackedFolders, forKey: Self.trackedFoldersKey)
    }

    // MARK: - Data Fetching

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        do {
            // Fetch PRs and scan worktrees in parallel
            async let prsTask = ghService.fetchAllPRs()
            async let wtTask = wtService.scanWorktrees(trackedFolders: trackedFolders)

            var prs = try await prsTask
            let wtMap = await wtTask
            worktreeMap = wtMap

            // Attach worktree info to PRs
            for i in prs.indices {
                let key = WorktreeService.WorktreeKey(
                    repoFullName: prs[i].repoFullName,
                    branch: prs[i].headRefName ?? "")
                prs[i].worktree = wtMap[key]
            }

            self.pullRequests = prs
            self.lastRefresh = Date()

            // Clear stale filters
            if let org = selectedOrg, !organizations.contains(org) {
                selectedOrg = nil
            }
            if let repo = selectedRepo, !repositories.contains(repo) {
                selectedRepo = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - PR Actions

    func confirmMerge(_ pr: PullRequest, strategy: MergeStrategy = .squash) {
        pendingAction = .merge(pr: pr, strategy: strategy)
    }

    func confirmClose(_ pr: PullRequest) {
        pendingAction = .close(pr: pr)
    }

    func confirmUpdateBranch(_ pr: PullRequest) {
        pendingAction = .updateBranch(pr: pr)
    }

    func confirmDeleteWorktree(_ pr: PullRequest) {
        pendingAction = .deleteWorktree(pr: pr)
    }

    /// Execute a PR action. Accepts an explicit action to avoid a race condition
    /// where the alert's isPresented binding clears `pendingAction` before the
    /// async Task body runs.
    func executeAction(_ explicitAction: PRAction? = nil) async {
        guard let action = explicitAction ?? pendingAction else { return }
        pendingAction = nil
        actionError = nil

        do {
            switch action {
            case .merge(let pr, let strategy):
                try await ghService.mergePR(
                    repo: pr.repoFullName, number: pr.number, strategy: strategy)
                // Optimistic removal — GitHub search index lags behind reality
                pullRequests.removeAll { $0.id == pr.id }
            case .close(let pr):
                try await ghService.closePR(repo: pr.repoFullName, number: pr.number)
                pullRequests.removeAll { $0.id == pr.id }
            case .updateBranch(let pr):
                try await ghService.updateBranch(repo: pr.repoFullName, number: pr.number)
            case .deleteWorktree(let pr, let force):
                guard let wt = pr.worktree else { return }
                try await wtService.removeWorktree(
                    mainRepoPath: wt.mainRepoPath, worktreePath: wt.path, force: force)
                // Clear worktree association so the card updates (or disappears from merged)
                if let idx = pullRequests.firstIndex(where: { $0.id == pr.id }) {
                    pullRequests[idx].worktree = nil
                }
            }
            // Background refresh to sync full state from GitHub
            await refresh()
        } catch {
            // If worktree remove failed (dirty), offer force delete
            if case .deleteWorktree(let pr, false) = action,
                error.localizedDescription.contains("contains modified or untracked files")
                    || error.localizedDescription.contains("is dirty")
            {
                actionError =
                    "Worktree has uncommitted changes. Force delete?"
                pendingAction = .deleteWorktree(pr: pr, force: true)
            } else {
                actionError = error.localizedDescription
            }
        }
    }

    func dismissAction() {
        pendingAction = nil
    }

    // MARK: - Auto-Refresh Timer

    func startAutoRefresh() {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Helpers

    var lastRefreshText: String {
        guard let lastRefresh else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Updated \(formatter.localizedString(for: lastRefresh, relativeTo: Date()))"
    }

    var totalFilteredCount: Int {
        filteredPRs.count
    }
}
