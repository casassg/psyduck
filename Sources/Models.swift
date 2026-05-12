import SwiftUI

// MARK: - Kanban Column

enum KanbanColumn: String, CaseIterable, Identifiable, Codable {
    case triage = "Triage"
    case plan = "Plan"
    case build = "Build"
    case draft = "Draft"
    case validation = "Validation"
    case inReview = "Waiting for Review"
    case approved = "Approved"
    case merged = "Merged"

    var id: String { rawValue }

    var accentColor: Color {
        switch self {
        case .triage: Theme.triageAccent
        case .plan: Theme.planAccent
        case .build: Theme.buildAccent
        case .draft: Theme.draftAccent
        case .inReview: Theme.inReviewAccent
        case .validation: Theme.validationAccent
        case .approved: Theme.approvedAccent
        case .merged: Theme.mergedAccent
        }
    }

    var iconName: String {
        switch self {
        case .triage: "tray.full"
        case .plan: "doc.text.magnifyingglass"
        case .build: "hammer"
        case .draft: "doc.text"
        case .inReview: "eye"
        case .validation: "gearshape.2"
        case .approved: "checkmark.circle"
        case .merged: "arrow.triangle.merge"
        }
    }

    var emptyMessage: String {
        switch self {
        case .triage: "No tasks to triage"
        case .plan: "No tasks being planned"
        case .build: "No tasks building"
        case .draft: "No draft PRs"
        case .inReview: "No PRs waiting for review"
        case .validation: "No CI issues"
        case .approved: "No approved PRs"
        case .merged: "No recent merges"
        }
    }

    /// Columns that display BoardTask items.
    var isTaskColumn: Bool {
        switch self {
        case .triage, .plan, .build: true
        default: false
        }
    }

    /// Columns that display PullRequest items.
    var isPRColumn: Bool {
        switch self {
        case .draft, .validation, .inReview, .approved, .merged: true
        default: false
        }
    }
}

// MARK: - Validation Status

/// Per-PR validation state within the Validation column.
enum ValidationStatus: Sendable, Equatable {
    case passing       // CLEAN — all checks green, mergeable
    case running       // CI still in progress
    case failing       // Required CI checks failed
    case conflicts     // Merge conflicts with base branch
    case behind        // Branch needs rebase onto base

    var label: String {
        switch self {
        case .passing: "Checks Passed"
        case .running: "CI Running"
        case .failing: "CI Failed"
        case .conflicts: "Merge Conflicts"
        case .behind: "Behind Base"
        }
    }

    var color: Color {
        switch self {
        case .passing: Theme.approvedAccent
        case .running: Theme.inReviewAccent
        case .failing: Theme.ciFailedColor
        case .conflicts: Theme.ciFailedColor
        case .behind: Theme.inReviewAccent
        }
    }

    var icon: String {
        switch self {
        case .passing: "checkmark.circle.fill"
        case .running: "arrow.triangle.2.circlepath"
        case .failing: "xmark.circle.fill"
        case .conflicts: "arrow.triangle.merge"
        case .behind: "arrow.up.circle.fill"
        }
    }
}

// MARK: - Pull Request

struct PullRequest: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let number: Int
    let title: String
    let repoOwner: String
    let repoName: String
    let isDraft: Bool
    let state: String  // "open" or "merged"
    let url: String
    let createdAt: Date
    let updatedAt: Date
    let commentsCount: Int

    // Enriched data from `gh pr view`
    var reviewDecision: String?
    var mergeStateStatus: String?  // CLEAN, BLOCKED, DIRTY, UNSTABLE, BEHIND, UNKNOWN
    var hasRunningRequiredChecks: Bool = false
    var hasFailedRequiredChecks: Bool = false
    var additions: Int?
    var deletions: Int?
    var headRefName: String?

    // Worktree association (populated by WorktreeService)
    var worktree: Worktree?

    var repoFullName: String { "\(repoOwner)/\(repoName)" }

    // MARK: - Validation

    var validationStatus: ValidationStatus {
        // Merge conflicts are distinct from CI failures
        if mergeStateStatus == "DIRTY" { return .conflicts }
        // Required check results take priority over mergeStateStatus,
        // because BEHIND can mask a failing required check.
        if hasFailedRequiredChecks { return .failing }
        if hasRunningRequiredChecks { return .running }
        switch mergeStateStatus {
        case "CLEAN": return .passing
        case "BEHIND": return .behind
        case "UNSTABLE": return .failing
        case "BLOCKED": return .failing
        default: return .passing
        }
    }

    // MARK: - Column Assignment

    /// Approved column = review approved AND CI green AND mergeable.
    /// Validation column = review approved but CI running, failing, or conflicts.
    /// Everything else: draft, in review, or merged.
    var column: KanbanColumn {
        if state == "merged" { return .merged }
        if isDraft { return .draft }
        if reviewDecision == "APPROVED" {
            switch validationStatus {
            case .passing: return .approved
            case .running, .failing, .conflicts, .behind: return .validation
            }
        }
        return .inReview
    }

    static func == (lhs: PullRequest, rhs: PullRequest) -> Bool {
        lhs.id == rhs.id
            && lhs.worktree?.path == rhs.worktree?.path
            && lhs.reviewDecision == rhs.reviewDecision
            && lhs.mergeStateStatus == rhs.mergeStateStatus
            && lhs.hasRunningRequiredChecks == rhs.hasRunningRequiredChecks
            && lhs.hasFailedRequiredChecks == rhs.hasFailedRequiredChecks
    }
}

// MARK: - Worktree

struct Worktree: Sendable, Equatable, Codable {
    let path: String
    let mainRepoPath: String
    let branch: String

    /// True if this is the main worktree (not a linked worktree).
    var isMain: Bool { path == mainRepoPath }

    var displayPath: String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Merge Strategy

enum MergeStrategy: String, CaseIterable, Identifiable {
    case squash = "Squash"
    case merge = "Merge Commit"
    case rebase = "Rebase"

    var id: String { rawValue }

    var ghFlag: String {
        switch self {
        case .squash: "--squash"
        case .merge: "--merge"
        case .rebase: "--rebase"
        }
    }
}

// MARK: - Open In App

struct OpenInApp: Identifiable, Sendable {
    let id: String
    let name: String
    let icon: String
    let command: String
    let resolvedPath: String

    func open(path: String) {
        let process = Process()
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
        ]

        switch id {
        case "ghostty":
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Ghostty", "--args", "--working-directory=\(path)"]
        default:
            process.executableURL = URL(fileURLWithPath: resolvedPath)
            process.arguments = [path]
        }

        try? process.run()
    }

    private static let knownApps: [(String, String, String, String)] = [
        ("zed", "Zed", "curlybraces", "zed"),
        ("vscode", "VS Code", "chevron.left.forwardslash.chevron.right", "code"),
        ("idea", "IntelliJ IDEA", "hammer", "idea"),
        ("ghostty", "Ghostty", "terminal", "ghostty"),
        ("finder", "Finder", "folder", "open"),
    ]

    static func detectInstalled() -> [OpenInApp] {
        knownApps.compactMap { (id, name, icon, command) in
            guard let resolvedPath = resolveCommand(command) else { return nil }
            return OpenInApp(
                id: id, name: name, icon: icon,
                command: command, resolvedPath: resolvedPath)
        }
    }

    private static func resolveCommand(_ command: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.environment = [
            "PATH":
                "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(NSHomeDirectory())/Library/Application Support/JetBrains/Toolbox/scripts",
            "HOME": NSHomeDirectory(),
        ]

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }
}

// MARK: - PR Action

enum PRAction: Identifiable {
    case merge(pr: PullRequest, strategy: MergeStrategy)
    case close(pr: PullRequest)
    case publish(pr: PullRequest)
    case updateBranch(pr: PullRequest)
    case deleteWorktree(pr: PullRequest, force: Bool = false)

    var id: String {
        switch self {
        case .merge(let pr, _): "merge-\(pr.id)"
        case .close(let pr): "close-\(pr.id)"
        case .publish(let pr): "publish-\(pr.id)"
        case .updateBranch(let pr): "update-\(pr.id)"
        case .deleteWorktree(let pr, _): "delete-wt-\(pr.id)"
        }
    }
}

// MARK: - Board Task

/// A task that flows through Triage -> Plan -> Build.
/// Source-agnostic: Linear sync hydrates these, but manual tasks are first-class.
struct BoardTask: Identifiable, Equatable, Sendable, Codable {
    let id: String
    var title: String
    var description: String?
    var priority: TaskPriority?
    var labels: [String]
    var branchName: String?
    var url: String?
    var comments: [TaskComment]
    var links: [String]

    // Linear sync metadata (nil for manual tasks)
    var linearId: String?
    var linearIdentifier: String?
    var linearUpdatedAt: Date?

    // Plan lifecycle (persisted)
    var planStatus: PlanStatus?
    var planPath: String?
    var selectedRepos: [String]?
    var worktrees: [TaskWorktree]?
    var userContext: String?             // extra context added by the user

    // Agent config per phase (chosen at start of plan/build)
    var planningAgentId: String?
    var planningModel: String?
    var planningVariant: String?
    var buildingAgentId: String?
    var buildingModel: String?
    var buildingVariant: String?

    // Repos selected for planning context or building worktrees
    var planningRepos: [String]?

    var draftPRRefs: [PRRef]?
    var createdAt: Date
    var updatedAt: Date

    /// Display identifier: Linear ticket ID, or short UUID for manual tasks.
    var displayIdentifier: String {
        if let linearIdentifier { return linearIdentifier }
        return String(id.prefix(8))
    }

    /// Folder-safe identifier for disk paths (worktrees, plans).
    var folderIdentifier: String {
        if let linearIdentifier { return linearIdentifier }
        return String(id.prefix(12))
    }
}

enum PlanStatus: String, Codable, Sendable {
    case readyForReview, revising
}

/// Whether an attached agent is planning or building.
enum AgentMode: String, Codable, Sendable {
    case planning, building
}

/// Persisted to ~/.psyduck/sessions.json so agents can be reattached on restart.
struct PersistedAgentSession: Codable, Sendable {
    let taskId: String
    let mode: AgentMode
    let agentId: String
    let model: String?
    let sessionId: String
    let workingDir: String
    let startedAt: Date
}

enum TaskPriority: Int, Codable, Sendable, CaseIterable {
    case urgent = 1, high = 2, medium = 3, low = 4

    var label: String {
        switch self {
        case .urgent: "Urgent"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

    var color: Color {
        switch self {
        case .urgent: Theme.ciFailedColor
        case .high: Theme.inReviewAccent
        case .medium: Theme.validationAccent
        case .low: Theme.textTertiary
        }
    }
}

struct TaskComment: Equatable, Sendable, Codable {
    let author: String
    let body: String
    let createdAt: Date
}

struct TaskWorktree: Equatable, Sendable, Codable {
    let repoFullName: String
    let branch: String
    let path: String
}

struct PRRef: Equatable, Sendable, Codable {
    let repoFullName: String
    let number: Int
    let url: String
}

// MARK: - Agent Configuration

struct AgentConfig: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var displayName: String
    var command: String
    var args: [String]
    var defaultModel: String?
    var defaultVariant: String?
    var acpNative: Bool
    var isAvailable: Bool

    // Populated at runtime by model/variant discovery
    var availableModels: [String]?
    var availableVariants: [String]?

    func processArgs(modelOverride: String?, variantOverride: String? = nil) -> [String] {
        var result = args
        if let model = modelOverride ?? defaultModel {
            switch id {
            case "opencode", "claude-code", "codex", "gemini":
                result += ["--model", model]
            default: break
            }
        }
        if let variant = variantOverride ?? defaultVariant {
            switch id {
            case "opencode":
                result += ["--variant", variant]
            default: break
            }
        }
        return result
    }

    /// Known built-in variants per agent.
    static let knownVariants: [String: [String]] = [
        "opencode": ["high", "max", "low", "medium", "xhigh", "none", "minimal"],
    ]

    static let builtIn: [AgentConfig] = [
        AgentConfig(id: "opencode", displayName: "OpenCode", command: "opencode",
                    args: [], defaultModel: nil, defaultVariant: nil,
                    acpNative: true, isAvailable: false),
        AgentConfig(id: "claude-code", displayName: "Claude Code", command: "claude",
                    args: [], defaultModel: nil, defaultVariant: nil,
                    acpNative: false, isAvailable: false),
        AgentConfig(id: "codex", displayName: "Codex", command: "codex",
                    args: [], defaultModel: nil, defaultVariant: nil,
                    acpNative: false, isAvailable: false),
        AgentConfig(id: "gemini", displayName: "Gemini CLI", command: "gemini",
                    args: [], defaultModel: nil, defaultVariant: nil,
                    acpNative: true, isAvailable: false),
        AgentConfig(id: "goose", displayName: "Goose", command: "goose",
                    args: [], defaultModel: nil, defaultVariant: nil,
                    acpNative: true, isAvailable: false),
    ]
}

struct AgentPreferences: Codable, Equatable, Sendable {
    var agents: [AgentConfig]
    var defaultPlanningAgentId: String?
    var defaultBuildingAgentId: String?
    var permissionPolicy: PermissionPolicy

    static let `default` = AgentPreferences(
        agents: AgentConfig.builtIn,
        defaultPlanningAgentId: nil,
        defaultBuildingAgentId: nil,
        permissionPolicy: .autoApprove
    )
}

enum PermissionPolicy: String, Codable, Sendable, CaseIterable {
    case autoApprove = "Auto-approve"
    case askUser = "Ask every time"
}

// MARK: - PR Agent Session

/// Tracks a PR card temporarily moved to the Build column for agent work.
struct PRAgentSession: Codable, Equatable, Sendable {
    let prId: String
    let repoFullName: String
    let worktreePath: String
    let agentId: String
    let model: String?
    let prompt: String
    let returnColumn: KanbanColumn
}

// MARK: - Linear DTO (transient, never persisted)

struct LinearTicketDTO: Decodable, Sendable {
    let id: String
    let identifier: String
    let title: String
    let description: String?
    let priority: Int?
    let state: LinearStateName
    let assignee: LinearUser?
    let creator: LinearUser?
    let labels: LinearLabelConnection
    let url: String
    let branchName: String?
    let comments: LinearCommentConnection
    let createdAt: String
    let updatedAt: String

    struct LinearStateName: Decodable, Sendable {
        let name: String
    }
    struct LinearUser: Decodable, Sendable {
        let name: String
    }
    struct LinearLabelConnection: Decodable, Sendable {
        let nodes: [LinearLabel]
    }
    struct LinearLabel: Decodable, Sendable {
        let name: String
    }
    struct LinearCommentConnection: Decodable, Sendable {
        let nodes: [LinearComment]
    }
    struct LinearComment: Decodable, Sendable {
        let body: String
        let createdAt: String
        let user: LinearUser?
    }

    func toBoardTask() -> BoardTask {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let created = isoFormatter.date(from: createdAt) ?? Date()
        let updated = isoFormatter.date(from: updatedAt) ?? Date()

        return BoardTask(
            id: UUID().uuidString,
            title: title,
            description: description,
            priority: TaskPriority(rawValue: priority ?? 0),
            labels: labels.nodes.map(\.name),
            branchName: branchName,
            url: url,
            comments: comments.nodes.map { c in
                TaskComment(
                    author: c.user?.name ?? "Unknown",
                    body: c.body,
                    createdAt: isoFormatter.date(from: c.createdAt) ?? Date()
                )
            },
            links: extractLinks(from: description, comments: comments.nodes.map(\.body)),
            linearId: id,
            linearIdentifier: identifier,
            linearUpdatedAt: updated,
            createdAt: created,
            updatedAt: updated
        )
    }

    private func extractLinks(from description: String?, comments: [String]) -> [String] {
        let allText = ([description].compactMap { $0 } + comments).joined(separator: "\n")
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(allText.startIndex..., in: allText)
        let matches = detector?.matches(in: allText, range: range) ?? []
        return matches.compactMap { match in
            guard let range = Range(match.range, in: allText) else { return nil }
            return String(allText[range])
        }
    }
}

// MARK: - JSON Decoding

struct SearchPRResult: Decodable, Sendable {
    let id: String
    let number: Int
    let title: String
    let repository: SearchRepo
    let isDraft: Bool
    let state: String
    let url: String
    let createdAt: String
    let updatedAt: String
    let commentsCount: Int

    struct SearchRepo: Decodable, Sendable {
        let name: String
        let nameWithOwner: String
    }
}

/// Shape from `gh pr view --json ...`
struct PRViewResult: Decodable, Sendable {
    let number: Int
    let reviewDecision: String
    let mergeStateStatus: String
    let additions: Int
    let deletions: Int
    let headRefName: String
}

/// Shape from `gh pr checks --required --json ...`
struct RequiredCheck: Decodable, Sendable {
    let bucket: String  // "pass", "fail", "pending", "skipping", "cancel"
}

// MARK: - Conversion

extension SearchPRResult {
    func toPullRequest() -> PullRequest {
        let parts = repository.nameWithOwner.split(separator: "/")
        let owner = parts.count > 0 ? String(parts[0]) : ""
        let name = parts.count > 1 ? String(parts[1]) : repository.name

        return PullRequest(
            id: id,
            number: number,
            title: title,
            repoOwner: owner,
            repoName: name,
            isDraft: isDraft,
            state: state.lowercased(),
            url: url,
            createdAt: ISO8601DateFormatter().date(from: createdAt) ?? Date(),
            updatedAt: ISO8601DateFormatter().date(from: updatedAt) ?? Date(),
            commentsCount: commentsCount
        )
    }
}
