import Foundation
import SwiftUI

@Observable
@MainActor
final class BoardViewModel {
    // MARK: - State

    var pullRequests: [PullRequest] = []
    var tasks: [BoardTask] = []
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
    var linearApiKey: String = "" {
        didSet { UserDefaults.standard.set(linearApiKey, forKey: Self.linearApiKeyKey) }
    }
    var agentPreferences: AgentPreferences = .default {
        didSet { persistAgentPreferences() }
    }

    // Manual task creation
    var showNewTaskSheet = false
    var newTaskTitle = ""
    var newTaskDescription = ""

    // Task detail view
    var selectedTask: BoardTask?

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
    private let linearService = LinearService()
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
    private static let linearApiKeyKey = "linearApiKey"
    private static let agentPrefsKey = "agentPreferences"

    init() {
        trackedFolders =
            UserDefaults.standard.stringArray(forKey: Self.trackedFoldersKey) ?? []
        linearApiKey = UserDefaults.standard.string(forKey: Self.linearApiKeyKey) ?? ""
        if let orgs = UserDefaults.standard.stringArray(forKey: Self.selectedOrgsKey) {
            selectedOrgs = Set(orgs)
        }
        if let repos = UserDefaults.standard.stringArray(forKey: Self.selectedReposKey) {
            selectedRepos = Set(repos)
        }
        if let prefsData = UserDefaults.standard.data(forKey: Self.agentPrefsKey),
           let prefs = try? JSONDecoder().decode(AgentPreferences.self, from: prefsData)
        {
            agentPreferences = prefs
        }
        availableApps = OpenInApp.detectInstalled()
        detectAvailableAgents()
        if let cached = cacheService.load() {
            pullRequests = cached.pullRequests
            tasks = cached.tasks
            lastRefresh = cached.lastRefresh
        }
    }

    /// Check which configured agents are actually available on PATH.
    private func detectAvailableAgents() {
        let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(NSHomeDirectory())/.local/bin"
        for i in agentPreferences.agents.indices {
            let command = agentPreferences.agents[i].command
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = [command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.environment = ["PATH": searchPath, "HOME": NSHomeDirectory()]
            do {
                try process.run()
                process.waitUntilExit()
                agentPreferences.agents[i].isAvailable = process.terminationStatus == 0
            } catch {
                agentPreferences.agents[i].isAvailable = false
            }
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

    // MARK: - Derived Task Column

    /// Column is derived from agent attachment + plan status — not stored on the task.
    func column(for task: BoardTask) -> KanbanColumn? {
        // Active building agent → Build
        if activeAgentSessions[task.id] == .building { return .build }
        // Active planning agent or plan ready for review → Plan
        if activeAgentSessions[task.id] == .planning { return .plan }
        if task.planStatus == .readyForReview || task.planStatus == .revising { return .plan }
        // Task has draft PRs → hidden (PR card handles it)
        if let refs = task.draftPRRefs, !refs.isEmpty { return nil }
        // Task's branch already has a PR → hidden
        if let branch = task.branchName,
           pullRequests.contains(where: { $0.headRefName == branch }) { return nil }
        // Otherwise → Triage
        return .triage
    }

    func tasks(for column: KanbanColumn) -> [BoardTask] {
        tasks
            .filter { self.column(for: $0) == column }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Check if an agent is attached to a task.
    func isAgentRunning(for taskId: String) -> Bool {
        activeAgentSessions[taskId] != nil
    }

    /// Get the agent mode for a task.
    func agentMode(for taskId: String) -> AgentMode? {
        activeAgentSessions[taskId]
    }

    // MARK: - Task Actions

    func createManualTask() {
        guard !newTaskTitle.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let task = BoardTask(
            id: UUID().uuidString,
            title: newTaskTitle.trimmingCharacters(in: .whitespaces),
            description: newTaskDescription.isEmpty ? nil : newTaskDescription,
            priority: nil,
            labels: [],
            branchName: nil,
            url: nil,
            comments: [],
            links: [],
            createdAt: Date(),
            updatedAt: Date()
        )
        tasks.append(task)
        newTaskTitle = ""
        newTaskDescription = ""
        showNewTaskSheet = false
        saveTasks()
    }

    func removeTask(_ task: BoardTask) {
        tasks.removeAll { $0.id == task.id }
        saveTasks()
    }

    func updateTaskContext(_ task: BoardTask, context: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[idx].userContext = context.isEmpty ? nil : context
        tasks[idx].updatedAt = Date()
        saveTasks()
    }

    // MARK: - Agent Orchestration

    /// Active agent sessions: taskId → mode. Source of truth for column derivation.
    var activeAgentSessions: [String: AgentMode] = [:]
    var agentOutputs: [String: [AgentOutputEvent]] = [:]
    var prAgentSessions: [String: PRAgentSession] = [:]
    var showPlanReview: BoardTask?

    private let contextService = TicketContextService()
    private let planService = PlanService()
    private let taskWorktreeService = TaskWorktreeService()
    private var acpClients: [String: ACPClient] = [:]
    private var agentTasks: [String: Task<Void, Never>] = [:]

    private static let sessionsFile: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".psyduck", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }()

    /// Start the planning agent for a task.
    func startPlanning(task: BoardTask, agentId: String, model: String?, variant: String?, repos: [String]) async {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[idx].planningAgentId = agentId
        tasks[idx].planningModel = model
        tasks[idx].planningVariant = variant
        tasks[idx].planningRepos = repos
        tasks[idx].updatedAt = Date()
        agentOutputs[task.id] = []
        activeAgentSessions[task.id] = .planning
        saveTasks()
        persistSessions()

        let taskId = task.id
        let currentTask = tasks[idx]

        agentTasks[taskId] = Task {
            do {
                // Export context
                let planDir = try contextService.exportContext(for: currentTask)

                // Clone selected repos for planning context
                let repoNames = currentTask.planningRepos ?? []
                let clonePaths = repoNames.isEmpty ? [] : try await contextService.cloneRepos(repoNames, into: planDir)

                // Build prompt
                let prompt = planService.buildPlanningPrompt(
                    task: currentTask, contextPath: planDir, repoClonePaths: clonePaths)

                // Find agent config
                guard let agentConfig = agentPreferences.agents.first(where: { $0.id == agentId }) else {
                    appendEvent(taskId: taskId, AgentOutputEvent(text: "Agent '\(agentId)' not configured", kind: .error))
                    return
                }

                // Connect ACP
                let variant = currentTask.planningVariant
                let args = agentConfig.processArgs(modelOverride: model, variantOverride: variant)
                let client = try await ACPClient.connect(command: agentConfig.command, args: args)
                acpClients[taskId] = client

                client.onUpdate = { [weak self] update in
                    Task { @MainActor in
                        let events = AgentOutputEvent.from(update: update)
                        for event in events {
                            self?.appendEvent(taskId: taskId, event)
                        }
                    }
                }

                let sessionId = try await client.createSession(cwd: planDir)
                let _ = try await client.prompt(
                    sessionId: sessionId,
                    content: [.text(prompt)]
                )

                // Agent finished — auto-advance to readyForReview
                await MainActor.run {
                    if let idx = self.tasks.firstIndex(where: { $0.id == taskId }) {
                        self.tasks[idx].planStatus = .readyForReview
                        self.tasks[idx].planPath = self.planService.planPath(for: self.tasks[idx]).path
                        self.tasks[idx].updatedAt = Date()
                    }
                    self.appendEvent(taskId: taskId, AgentOutputEvent(text: "Plan complete", kind: .completed))
                    self.activeAgentSessions.removeValue(forKey: taskId)
                    self.persistSessions()
                    self.saveTasks()
                }

                try? await client.closeSession(id: sessionId)
                client.kill()
                acpClients.removeValue(forKey: taskId)

            } catch {
                await MainActor.run {
                    self.appendEvent(taskId: taskId, AgentOutputEvent(text: "Error: \(error.localizedDescription)", kind: .error))
                    self.activeAgentSessions.removeValue(forKey: taskId)
                    self.persistSessions()
                    if let idx = self.tasks.firstIndex(where: { $0.id == taskId }) {
                        self.tasks[idx].planStatus = nil
                    }
                }
            }
        }
    }

    /// Revise a plan with review comments.
    func revisePlan(task: BoardTask) async {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[idx].planStatus = .revising
        tasks[idx].updatedAt = Date()
        agentOutputs[task.id] = []
        activeAgentSessions[task.id] = .planning
        saveTasks()
        persistSessions()

        let taskId = task.id
        let currentTask = tasks[idx]
        let agentId = currentTask.planningAgentId ?? agentPreferences.defaultPlanningAgentId ?? ""
        let model = currentTask.planningModel

        agentTasks[taskId] = Task {
            do {
                guard let agentConfig = agentPreferences.agents.first(where: { $0.id == agentId }) else {
                    appendEvent(taskId: taskId, AgentOutputEvent(text: "Agent not configured", kind: .error))
                    return
                }

                let planDir = try contextService.exportContext(for: currentTask)
                let prompt = planService.buildRevisionPrompt(task: currentTask)
                let variant = currentTask.planningVariant
                let args = agentConfig.processArgs(modelOverride: model, variantOverride: variant)
                let client = try await ACPClient.connect(command: agentConfig.command, args: args)
                acpClients[taskId] = client

                client.onUpdate = { [weak self] update in
                    Task { @MainActor in
                        for event in AgentOutputEvent.from(update: update) {
                            self?.appendEvent(taskId: taskId, event)
                        }
                    }
                }

                let sessionId = try await client.createSession(cwd: planDir)
                let _ = try await client.prompt(sessionId: sessionId, content: [.text(prompt)])

                await MainActor.run {
                    if let idx = self.tasks.firstIndex(where: { $0.id == taskId }) {
                        self.tasks[idx].planStatus = .readyForReview
                        self.tasks[idx].updatedAt = Date()
                    }
                    self.appendEvent(taskId: taskId, AgentOutputEvent(text: "Revision complete", kind: .completed))
                    self.activeAgentSessions.removeValue(forKey: taskId)
                    self.persistSessions()
                    self.saveTasks()
                }

                try? await client.closeSession(id: sessionId)
                client.kill()
                acpClients.removeValue(forKey: taskId)
            } catch {
                await MainActor.run {
                    self.appendEvent(taskId: taskId, AgentOutputEvent(text: "Error: \(error.localizedDescription)", kind: .error))
                    self.activeAgentSessions.removeValue(forKey: taskId)
                    self.persistSessions()
                }
            }
        }
    }

    /// Approve a plan and start building.
    func approvePlanAndBuild(task: BoardTask, repos: [String], agentId: String, model: String?, variant: String?) async {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[idx].planStatus = nil
        tasks[idx].selectedRepos = repos
        tasks[idx].buildingAgentId = agentId
        tasks[idx].buildingModel = model
        tasks[idx].buildingVariant = variant
        tasks[idx].updatedAt = Date()
        agentOutputs[task.id] = []
        activeAgentSessions[task.id] = .building
        saveTasks()
        persistSessions()

        let taskId = task.id
        let currentTask = tasks[idx]

        agentTasks[taskId] = Task {
            do {
                // Create worktrees
                let repoTuples = repos.compactMap { fullName -> (String, URL)? in
                    guard let localPath = findLocalRepo(fullName) else { return nil }
                    return (fullName, localPath)
                }

                appendEvent(taskId: taskId, AgentOutputEvent(text: "Creating worktrees...", kind: .execute))
                let worktrees = try await taskWorktreeService.createWorktrees(
                    for: currentTask, repos: repoTuples)

                await MainActor.run {
                    if let idx = self.tasks.firstIndex(where: { $0.id == taskId }) {
                        self.tasks[idx].worktrees = worktrees
                    }
                }

                guard let firstWorktree = worktrees.first else {
                    appendEvent(taskId: taskId, AgentOutputEvent(text: "No worktrees created", kind: .error))
                    return
                }

                // Build prompt
                let planPath = planService.planPath(for: currentTask)
                let contextPath = try contextService.exportContext(for: currentTask)
                var prompt = """
                    Implement a feature based on an approved plan.

                    Plan: \(planPath.path)
                    Task context: \(contextPath.appendingPathComponent("context.md").path)

                    You are working in these worktrees:

                    """
                for wt in worktrees {
                    prompt += "- \(wt.repoFullName): \(wt.path)\n"
                }
                prompt += """

                    For each repo:
                    1. Read the plan.
                    2. Make changes.
                    3. Run tests.
                    4. Commit with descriptive messages.

                    When done, push and create a draft PR for each repo via:
                    gh pr create --draft --title "\(currentTask.displayIdentifier): \(currentTask.title)"
                    """

                guard let agentConfig = agentPreferences.agents.first(where: { $0.id == agentId }) else {
                    appendEvent(taskId: taskId, AgentOutputEvent(text: "Agent not configured", kind: .error))
                    return
                }

                let buildVariant = currentTask.buildingVariant
                let args = agentConfig.processArgs(modelOverride: model, variantOverride: buildVariant)
                let client = try await ACPClient.connect(command: agentConfig.command, args: args)
                acpClients[taskId] = client

                client.onUpdate = { [weak self] update in
                    Task { @MainActor in
                        for event in AgentOutputEvent.from(update: update) {
                            self?.appendEvent(taskId: taskId, event)
                        }
                    }
                }

                let sessionId = try await client.createSession(
                    cwd: URL(fileURLWithPath: firstWorktree.path))
                let _ = try await client.prompt(sessionId: sessionId, content: [.text(prompt)])

                // Agent finished — detach. Task hides from board once PR appears after refresh.
                await MainActor.run {
                    if let idx = self.tasks.firstIndex(where: { $0.id == taskId }) {
                        self.tasks[idx].updatedAt = Date()
                    }
                    self.appendEvent(taskId: taskId, AgentOutputEvent(text: "Build complete — draft PR created", kind: .completed))
                    self.activeAgentSessions.removeValue(forKey: taskId)
                    self.persistSessions()
                    self.saveTasks()
                }

                try? await client.closeSession(id: sessionId)
                client.kill()
                acpClients.removeValue(forKey: taskId)

                // Refresh to pick up the new draft PR
                await refresh()

            } catch {
                await MainActor.run {
                    self.appendEvent(taskId: taskId, AgentOutputEvent(text: "Error: \(error.localizedDescription)", kind: .error))
                    self.activeAgentSessions.removeValue(forKey: taskId)
                    self.persistSessions()
                }
            }
        }
    }

    /// Start an agent on a PR card (from Draft/Validation/InReview).
    /// Moves the PR to Build temporarily.
    func startAgentOnPR(pr: PullRequest, agentId: String, model: String?, prompt: String) async {
        guard let worktree = pr.worktree else { return }

        let session = PRAgentSession(
            prId: pr.id,
            repoFullName: pr.repoFullName,
            worktreePath: worktree.path,
            agentId: agentId,
            model: model,
            prompt: prompt,
            returnColumn: pr.column
        )
        prAgentSessions[pr.id] = session
        agentOutputs[pr.id] = []
        activeAgentSessions[pr.id] = .building

        let prId = pr.id

        agentTasks[prId] = Task {
            do {
                guard let agentConfig = agentPreferences.agents.first(where: { $0.id == agentId }) else {
                    appendEvent(taskId: prId, AgentOutputEvent(text: "Agent not configured", kind: .error))
                    return
                }

                let args = agentConfig.processArgs(modelOverride: model)
                let client = try await ACPClient.connect(command: agentConfig.command, args: args)
                acpClients[prId] = client

                client.onUpdate = { [weak self] update in
                    Task { @MainActor in
                        for event in AgentOutputEvent.from(update: update) {
                            self?.appendEvent(taskId: prId, event)
                        }
                    }
                }

                let sessionId = try await client.createSession(
                    cwd: URL(fileURLWithPath: worktree.path))
                let _ = try await client.prompt(sessionId: sessionId, content: [.text(prompt)])

                await MainActor.run {
                    self.appendEvent(taskId: prId, AgentOutputEvent(text: "Done — changes pushed", kind: .completed))
                    self.activeAgentSessions.removeValue(forKey: prId)
                    self.prAgentSessions.removeValue(forKey: prId)
                }

                try? await client.closeSession(id: sessionId)
                client.kill()
                acpClients.removeValue(forKey: prId)

                await refresh()

            } catch {
                await MainActor.run {
                    self.appendEvent(taskId: prId, AgentOutputEvent(text: "Error: \(error.localizedDescription)", kind: .error))
                    self.activeAgentSessions.removeValue(forKey: prId)
                    self.prAgentSessions.removeValue(forKey: prId)
                }
            }
        }
    }

    /// Send a steering message to a running agent.
    func steerAgent(id: String, message: String) {
        // Steering is done via a follow-up prompt on the same session.
        // The current prompt must complete first. For now, append as an event.
        appendEvent(taskId: id, AgentOutputEvent(text: "You: \(message)", kind: .message))
        // TODO: queue steering messages for next prompt turn
    }

    /// Cancel a running agent.
    func cancelAgent(id: String) {
        agentTasks[id]?.cancel()
        agentTasks.removeValue(forKey: id)
        acpClients[id]?.kill()
        acpClients.removeValue(forKey: id)
        activeAgentSessions.removeValue(forKey: id)
        prAgentSessions.removeValue(forKey: id)
        persistSessions()
        appendEvent(taskId: id, AgentOutputEvent(text: "Cancelled", kind: .error))
    }

    private func appendEvent(taskId: String, _ event: AgentOutputEvent) {
        if agentOutputs[taskId] == nil {
            agentOutputs[taskId] = []
        }
        agentOutputs[taskId]?.append(event)
    }

    /// Find the local path for a repo full name from tracked folders.
    private func findLocalRepo(_ fullName: String) -> URL? {
        for key in worktreeMap.keys where key.repoFullName == fullName {
            if let wt = worktreeMap[key] {
                return URL(fileURLWithPath: wt.mainRepoPath)
            }
        }
        return nil
    }

    /// Get all repo full names from tracked worktrees.
    func trackedRepoNames() -> [String] {
        Array(Set(worktreeMap.keys.map(\.repoFullName))).sorted()
    }

    /// Repo names filtered by the current org/repo filter pills.
    func filteredRepoNames() -> [String] {
        trackedRepoNames().filter { repo in
            if !selectedOrgs.isEmpty {
                let owner = repo.split(separator: "/").first.map(String.init) ?? ""
                if !selectedOrgs.contains(owner) { return false }
            }
            if !selectedRepos.isEmpty, !selectedRepos.contains(repo) { return false }
            return true
        }
    }

    /// Discover available models for agents that support model listing.
    func discoverAgentModels() async {
        for i in agentPreferences.agents.indices {
            guard agentPreferences.agents[i].isAvailable else { continue }
            switch agentPreferences.agents[i].id {
            case "opencode":
                if let models = await runModelDiscovery(command: "opencode", args: ["models"]) {
                    agentPreferences.agents[i].availableModels = models
                }
                // Set known variants
                agentPreferences.agents[i].availableVariants = AgentConfig.knownVariants["opencode"]
            default:
                if let variants = AgentConfig.knownVariants[agentPreferences.agents[i].id] {
                    agentPreferences.agents[i].availableVariants = variants
                }
            }
        }
    }

    /// Run a model discovery command and parse lines of output into model names.
    private func runModelDiscovery(command: String, args: [String]) async -> [String]? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(NSHomeDirectory())/.local/bin"
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.environment = ["PATH": searchPath, "HOME": NSHomeDirectory()]

            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                continuation.resume(returning: nil)
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                continuation.resume(returning: nil)
                return
            }
            // Parse lines: each non-empty line is a model name (provider/model format)
            let models = output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("─") && !$0.hasPrefix("Provider") && $0.contains("/") }
            continuation.resume(returning: models.isEmpty ? nil : models)
        }
    }

    // MARK: - Session Persistence + Reattachment

    /// Persist active agent sessions to disk for reattachment on restart.
    func persistSessions() {
        let sessions = activeAgentSessions.compactMap { (taskId, mode) -> PersistedAgentSession? in
            guard let task = tasks.first(where: { $0.id == taskId }) else { return nil }
            let agentId = mode == .planning ? task.planningAgentId : task.buildingAgentId
            let model = mode == .planning ? task.planningModel : task.buildingModel
            guard let agentId else { return nil }
            return PersistedAgentSession(
                taskId: taskId,
                mode: mode,
                agentId: agentId,
                model: model,
                sessionId: "", // ACP session ID would be stored here in a full implementation
                workingDir: "", // working dir stored here
                startedAt: Date()
            )
        }
        let dir = Self.sessionsFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(sessions) {
            try? data.write(to: Self.sessionsFile, options: .atomic)
        }
    }

    /// On app launch, attempt to reattach agent sessions from disk.
    /// If the agent supports ACP session/load, we can resume. Otherwise, task falls to Triage.
    func reattachSessions() async {
        guard let data = try? Data(contentsOf: Self.sessionsFile),
              let sessions = try? JSONDecoder().decode([PersistedAgentSession].self, from: data),
              !sessions.isEmpty
        else { return }

        for session in sessions {
            guard let agentConfig = agentPreferences.agents.first(where: { $0.id == session.agentId }),
                  agentConfig.isAvailable
            else { continue }

            // Try to relaunch the agent and resume the session
            do {
                let args = agentConfig.processArgs(modelOverride: session.model)
                let client = try await ACPClient.connect(command: agentConfig.command, args: args)

                // Try session/load (agent must support loadSession capability)
                if !session.sessionId.isEmpty {
                    try await client.loadSession(id: session.sessionId)
                }

                acpClients[session.taskId] = client
                activeAgentSessions[session.taskId] = session.mode
                agentOutputs[session.taskId] = [
                    AgentOutputEvent(text: "Session reattached", kind: .completed)
                ]

                client.onUpdate = { [weak self] update in
                    let taskId = session.taskId
                    Task { @MainActor in
                        for event in AgentOutputEvent.from(update: update) {
                            self?.appendEvent(taskId: taskId, event)
                        }
                    }
                }
            } catch {
                // Reattachment failed — task falls back to Triage naturally
            }
        }

        // Clean up sessions file if nothing reattached
        if activeAgentSessions.isEmpty {
            try? FileManager.default.removeItem(at: Self.sessionsFile)
        }
    }

    private func saveTasks() {
        if let lastRefresh {
            cacheService.save(pullRequests: pullRequests, tasks: tasks, lastRefresh: lastRefresh)
        }
    }

    private func persistAgentPreferences() {
        if let data = try? JSONEncoder().encode(agentPreferences) {
            UserDefaults.standard.set(data, forKey: Self.agentPrefsKey)
        }
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

        // Linear sync (non-blocking — failure just means stale tasks)
        if !linearApiKey.isEmpty {
            do {
                let tickets = try await linearService.fetchMyTickets(apiKey: linearApiKey)
                if !Task.isCancelled {
                    tasks = linearService.sync(tickets: tickets, into: tasks)
                }
            } catch {
                // Linear sync failure is non-fatal — keep existing tasks
            }
        }

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
                cacheService.save(pullRequests: pullRequests, tasks: tasks, lastRefresh: lastRefresh)
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
