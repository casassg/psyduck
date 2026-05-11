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

    // Filters (multi-select: empty set = all, persisted across sessions)
    var selectedOrgs: Set<String> = [] {
        didSet { persistFilters() }
    }
    var selectedRepos: Set<String> = [] {
        didSet { persistFilters() }
    }

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

    // Setup errors (gh not installed or not authenticated)
    enum SetupStatus: Equatable {
        case ok
        case ghNotInstalled
        case ghNotAuthenticated
    }
    var setupStatus: SetupStatus = .ok

    // MARK: - Private

    private let ghService = GitHubService()
    private let wtService = WorktreeService()
    private let cacheService = CacheService()
    private var worktreeMap: [WorktreeService.WorktreeKey: Worktree] = [:]
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    /// PR IDs recently acted on (merge/close) with the time of action.
    /// Used to suppress stale search-index results for a grace period.
    private var recentlyActedPRs: [String: Date] = [:]
    private static let actedGracePeriod: TimeInterval = 60

    private static let trackedFoldersKey = "trackedFolders"
    private static let selectedOrgsKey = "selectedOrgs"
    private static let selectedReposKey = "selectedRepos"

    init() {
        trackedFolders =
            UserDefaults.standard.stringArray(forKey: Self.trackedFoldersKey) ?? []
        if let orgs = UserDefaults.standard.stringArray(forKey: Self.selectedOrgsKey) {
            selectedOrgs = Set(orgs)
        }
        if let repos = UserDefaults.standard.stringArray(forKey: Self.selectedReposKey) {
            selectedRepos = Set(repos)
        }
        availableApps = OpenInApp.detectInstalled()
        if let cached = cacheService.load() {
            pullRequests = cached.pullRequests
            lastRefresh = cached.lastRefresh
        }
    }

    // MARK: - Computed (filtered)

    private var filteredPRs: [PullRequest] {
        pullRequests.filter { pr in
            if !selectedOrgs.isEmpty, !selectedOrgs.contains(pr.repoOwner) { return false }
            if !selectedRepos.isEmpty, !selectedRepos.contains(pr.repoFullName) { return false }
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
            selectedOrgs.isEmpty || selectedOrgs.contains(pr.repoOwner)
        }
        return Array(Set(repos.map(\.repoFullName))).sorted()
    }

    var hasActiveFilters: Bool {
        !selectedOrgs.isEmpty || !selectedRepos.isEmpty
    }

    func toggleOrg(_ org: String) {
        if selectedOrgs.contains(org) {
            selectedOrgs.remove(org)
        } else {
            selectedOrgs.insert(org)
        }
        // Clear repos that no longer match selected orgs
        if !selectedOrgs.isEmpty {
            selectedRepos = selectedRepos.filter { repo in
                let owner = repo.split(separator: "/").first.map(String.init) ?? ""
                return selectedOrgs.contains(owner)
            }
        }
    }

    func toggleRepo(_ repo: String) {
        if selectedRepos.contains(repo) {
            selectedRepos.remove(repo)
        } else {
            selectedRepos.insert(repo)
        }
    }

    func clearFilters() {
        selectedOrgs.removeAll()
        selectedRepos.removeAll()
    }

    // MARK: - Tracked Folders

    func addTrackedFolder(_ path: String) {
        guard !trackedFolders.contains(path) else { return }
        trackedFolders.append(path)
        Task { await refresh() }
    }

    func removeTrackedFolder(at offsets: IndexSet) {
        trackedFolders.remove(atOffsets: offsets)
        Task { await refresh() }
    }

    func removeTrackedFolder(_ path: String) {
        trackedFolders.removeAll { $0 == path }
        Task { await refresh() }
    }

    private func persistTrackedFolders() {
        UserDefaults.standard.set(trackedFolders, forKey: Self.trackedFoldersKey)
    }

    private func persistFilters() {
        UserDefaults.standard.set(Array(selectedOrgs), forKey: Self.selectedOrgsKey)
        UserDefaults.standard.set(Array(selectedRepos), forKey: Self.selectedReposKey)
    }

    // MARK: - Data Fetching

    /// Cancel any in-flight refresh and start a fresh one.
    func refresh() async {
        refreshTask?.cancel()

        let task = Task { @MainActor in
            await performRefresh()
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh() async {
        let status = ghService.checkSetup()
        setupStatus = status
        guard status == .ok else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        async let wtTask = wtService.scanWorktrees(trackedFolders: trackedFolders)

        // Pass current PRs so enrichment data is carried forward on failure.
        var fetchedPRs: [PullRequest]?
        do {
            fetchedPRs = try await ghService.fetchAllPRs(existing: pullRequests)
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }

        // Bail out if a newer refresh superseded us
        guard !Task.isCancelled else { return }

        let wtMap = await wtTask
        worktreeMap = wtMap

        if var prs = fetchedPRs {
            // Expire old entries from the grace-period set.
            let now = Date()
            recentlyActedPRs = recentlyActedPRs.filter {
                now.timeIntervalSince($0.value) < Self.actedGracePeriod
            }

            // Suppress PRs that were recently merged/closed to prevent
            // stale search-index results from reverting optimistic removal.
            if !recentlyActedPRs.isEmpty {
                prs.removeAll { recentlyActedPRs[$0.id] != nil }
            }

            // Merge worktree data into the fetched PRs before assignment
            // so the board never sees PRs without worktree associations.
            for i in prs.indices {
                let key = WorktreeService.WorktreeKey(
                    repoFullName: prs[i].repoFullName,
                    branch: prs[i].headRefName ?? "")
                prs[i].worktree = wtMap[key]
            }

            // Single atomic assignment — board goes from old state to new in one step.
            self.pullRequests = prs
            self.lastRefresh = Date()

            if let lastRefresh {
                cacheService.save(pullRequests: pullRequests, lastRefresh: lastRefresh)
            }
        }
    }

    // MARK: - PR Actions

    func confirmMerge(_ pr: PullRequest, strategy: MergeStrategy = .squash) {
        pendingAction = .merge(pr: pr, strategy: strategy)
    }

    func confirmClose(_ pr: PullRequest) {
        pendingAction = .close(pr: pr)
    }

    func confirmPublish(_ pr: PullRequest) {
        pendingAction = .publish(pr: pr)
    }

    func confirmUpdateBranch(_ pr: PullRequest) {
        pendingAction = .updateBranch(pr: pr)
    }

    func confirmDeleteWorktree(_ pr: PullRequest) {
        pendingAction = .deleteWorktree(pr: pr)
    }

    func executeAction(_ explicitAction: PRAction? = nil) async {
        guard let action = explicitAction ?? pendingAction else { return }
        pendingAction = nil
        actionError = nil

        do {
            switch action {
            case .merge(let pr, let strategy):
                try await ghService.mergePR(
                    repo: pr.repoFullName, number: pr.number, strategy: strategy)
                recentlyActedPRs[pr.id] = Date()
                pullRequests.removeAll { $0.id == pr.id }
            case .close(let pr):
                try await ghService.closePR(repo: pr.repoFullName, number: pr.number)
                recentlyActedPRs[pr.id] = Date()
                pullRequests.removeAll { $0.id == pr.id }
            case .publish(let pr):
                try await ghService.publishPR(repo: pr.repoFullName, number: pr.number)
                // Optimistic: flip isDraft so it moves to In Review immediately
                if let idx = pullRequests.firstIndex(where: { $0.id == pr.id }) {
                    pullRequests[idx] = PullRequest(
                        id: pr.id, number: pr.number, title: pr.title,
                        repoOwner: pr.repoOwner, repoName: pr.repoName,
                        isDraft: false, state: pr.state, url: pr.url,
                        createdAt: pr.createdAt, updatedAt: pr.updatedAt,
                        commentsCount: pr.commentsCount,
                        reviewDecision: pr.reviewDecision,
                        mergeStateStatus: pr.mergeStateStatus,
                        additions: pr.additions, deletions: pr.deletions,
                        headRefName: pr.headRefName, worktree: pr.worktree)
                }
            case .updateBranch(let pr):
                try await ghService.updateBranch(repo: pr.repoFullName, number: pr.number)
            case .deleteWorktree(let pr, let force):
                guard let wt = pr.worktree else { return }
                try await wtService.removeWorktree(
                    mainRepoPath: wt.mainRepoPath, worktreePath: wt.path, force: force)
                if let idx = pullRequests.firstIndex(where: { $0.id == pr.id }) {
                    pullRequests[idx].worktree = nil
                }
            }
            await refresh()
        } catch {
            if case .deleteWorktree(let pr, false) = action,
                error.localizedDescription.contains("contains modified or untracked files")
                    || error.localizedDescription.contains("is dirty")
            {
                actionError = "Worktree has uncommitted changes. Force delete?"
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
        let timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
        // .common mode ensures the timer fires even during scrolling or menu interaction
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
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
}
