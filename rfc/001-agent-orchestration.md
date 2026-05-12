# RFC 001: Agent-Orchestrated Task Pipeline

**Status**: Draft
**Date**: 2026-05-11
**Author**: gerardc (AI-assisted)

## Summary

Extend PsyDuck from a GitHub PR kanban board into a full task-lifecycle tool. Three new columns—Triage, Plan, Build—bridge tasks to agent-generated code and draft PRs. Existing PR columns gain an "Agent" button for any card with a local worktree. Agent communication uses [ACP (Agent Client Protocol)](https://agentclientprotocol.com), giving compatibility with 30+ coding agents through a single protocol implementation.

Inspired by [OpenAI Harness Engineering](https://openai.com/index/harness-engineering/) and [Symphony](https://github.com/openai/symphony).

## Columns (8, horizontal scroll)

```
Triage → Plan → Build → Draft → Validation → In Review → Approved → Merged
           ↑              ↑                       │
           └── (revise) ──┘   (Agent button) ─────┘
                              moves PR to Build temporarily
```

- **Triage**: Tasks from Linear sync + manual creation. Filter pills for team/project.
- **Plan**: Agent generates RFC/plan. Card shows agent output while running, "Ready for Review" badge when done. User reviews in sheet overlay, approves (pick repos → Build) or revises (stays in Plan, agent re-runs with comments).
- **Build**: Agent codes in worktrees, pushes, creates draft PR via `gh` → card exits to Draft. Also temporarily hosts PR cards sent from Draft/Validation/InReview via the "Agent" button.
- **Draft–Merged**: Existing PR columns. Any card with a detected local worktree gets an "Agent" button (pick agent/model, write prompt or use quick actions → card moves to Build temporarily → returns to correct PR column when agent finishes and pushes).

## Data Model

### BoardTask

Source-agnostic. Linear is a sync source that hydrates these; manual tasks are first-class.

```swift
struct BoardTask: Identifiable, Equatable, Sendable, Codable {
    let id: String                      // UUID
    var title: String
    var description: String?
    var priority: TaskPriority?
    var labels: [String]
    var branchName: String?             // from Linear or user-provided
    var url: String?                    // Linear URL, nil for manual tasks
    var comments: [TaskComment]
    var links: [String]                 // extracted URLs (Slack threads, docs)

    // Linear sync metadata (nil for manual tasks)
    var linearId: String?
    var linearIdentifier: String?       // "ENG-123"
    var linearUpdatedAt: Date?

    // Lifecycle
    var phase: TaskPhase
    var planStatus: PlanStatus?         // only relevant when phase == .plan
    var planPath: URL?
    var selectedRepos: [String]?
    var worktrees: [TaskWorktree]?

    // Agent config per phase (chosen at start of plan/build)
    var planningAgentId: String?
    var planningModel: String?
    var buildingAgentId: String?
    var buildingModel: String?

    var draftPRRefs: [PRRef]?
    var createdAt: Date
    var updatedAt: Date
}

enum TaskPhase: String, Codable { case triage, plan, build }

enum PlanStatus: String, Codable { case agentRunning, readyForReview, revising }

enum TaskPriority: Int, Codable { case urgent = 1, high = 2, medium = 3, low = 4 }

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
```

### PRAgentSession

Tracks a PR card temporarily moved to Build.

```swift
struct PRAgentSession: Codable, Equatable, Sendable {
    let prNumber: Int
    let repoFullName: String
    let worktreePath: String
    let agentId: String
    let model: String?
    let prompt: String
    let returnColumn: KanbanColumn
}
```

### KanbanColumn

```swift
enum KanbanColumn: String, CaseIterable, Identifiable {
    case triage, plan, build
    case draft, validation, inReview, approved, merged
}
```

### Agent Configuration

```swift
struct AgentConfig: Codable, Equatable, Sendable, Identifiable {
    let id: String              // "opencode", "claude-code", "codex", etc.
    var displayName: String
    var command: String          // binary name or path
    var args: [String]           // extra CLI args
    var defaultModel: String?    // e.g. "claude-sonnet-4"
    var acpNative: Bool          // true if agent speaks ACP without a wrapper
    var isAvailable: Bool        // true if binary found on PATH
}

struct AgentPreferences: Codable, Equatable, Sendable {
    var agents: [AgentConfig]
    var defaultPlanningAgentId: String?
    var defaultBuildingAgentId: String?
    var permissionPolicy: PermissionPolicy
}

enum PermissionPolicy: String, Codable { case autoApprove, askUser }
```

Model is passed to the agent subprocess via CLI flag (`--model`) or env var, depending on agent. Small mapping table in `AgentConfig`:

```swift
extension AgentConfig {
    func processArgs(modelOverride: String?) -> [String] {
        var result = args
        if let model = modelOverride ?? defaultModel {
            switch id {
            case "opencode", "claude-code", "codex", "gemini":
                result += ["--model", model]
            default: break
            }
        }
        return result
    }
}
```

## Agent Communication: ACP

PsyDuck is an [ACP Client](https://agentclientprotocol.com/get-started/architecture). Single implementation, works with any ACP-compatible agent.

### Why ACP

ACP is "LSP for coding agents"—JSON-RPC 2.0 over stdio. Instead of writing custom adapters for each agent's proprietary CLI, we implement ACP once. Compatible agents include OpenCode (native), Claude Code (via `claude-agent-acp`), Codex CLI (via `codex-acp`), Goose, Gemini CLI, GitHub Copilot, Cursor, Cline, Kiro CLI, and 20+ more.

### ACPClient

```swift
final class ACPClient: @unchecked Sendable {
    // Lifecycle
    static func connect(command: String, args: [String], env: [String: String]) async throws -> ACPClient

    // Sessions
    func createSession(cwd: URL, mcpServers: [MCPServerConfig]?) async throws -> String
    func closeSession(id: String) async throws

    // Prompts (initial + steering follow-ups)
    func prompt(sessionId: String, content: [ACPContentBlock]) async throws -> ACPStopReason

    // Streaming updates (notifications from agent)
    var onUpdate: (@Sendable (ACPSessionUpdate) -> Void)?
    var onPermissionRequest: (@Sendable (ACPPermissionRequest) async -> ACPPermissionResponse)?

    // Control
    func cancel(sessionId: String) async
    func kill()
}
```

### Client Capabilities

PsyDuck advertises during `initialize`:

```json
{
    "clientCapabilities": {
        "fs": { "readTextFile": true, "writeTextFile": true },
        "terminal": true
    },
    "clientInfo": { "name": "psyduck", "title": "PsyDuck", "version": "2.0.0" }
}
```

- **fs**: Agent calls `fs/read_text_file` and `fs/write_text_file` → PsyDuck reads/writes files scoped to workspace.
- **terminal**: Agent calls `terminal/create` → PsyDuck spawns subprocess, streams output.
- **permissions**: Agent calls `session/request_permission` → auto-approve or prompt user.

### ACP Session Updates → UI

| ACP Update | UI Rendering |
|---|---|
| `agent_message_chunk` (text) | Streaming text in output view |
| `plan` (entries) | Checklist with priority badges and status icons |
| `tool_call` kind=`read` | "Reading src/auth.ts" with file icon |
| `tool_call` kind=`edit` + `diff` | Inline diff viewer |
| `tool_call` kind=`execute` + `terminal` | Live terminal output |
| `tool_call` kind=`search` | Search results |
| `tool_call` kind=`think` | Thinking indicator |

### Steering

Works naturally via ACP. Agent finishes a turn → `session/prompt` returns. User types a follow-up → PsyDuck sends another `session/prompt` on the same session. Same context, no hacks.

## Linear Sync

`LinearService` fetches tickets via GraphQL API (`https://api.linear.app/graphql`) using a personal API key. Returns transient `LinearTicketDTO` structs. Sync logic upserts into `[BoardTask]`:

- New tickets → create `BoardTask` with `linearId` set, `phase: .triage`.
- Existing tickets → update title, description, comments, labels, branchName if `updatedAt` is newer.
- Tickets gone from API → remove only if task is still in `.triage`. Tasks in Plan/Build/beyond are never auto-removed.
- No writes to Linear (read-only).

## Worktree Management

Worktrees live under `~/.psyduck/worktrees/{identifier}/{repo-name}/`. Identifier is the Linear identifier (e.g. `ENG-123`) or a short UUID prefix for manual tasks.

### Creation Sequence

```
1. git fetch origin
2. default_branch = gh api repos/{owner}/{repo} --jq .default_branch
3. if origin/{branchName} exists:
     git worktree add <path> origin/{branchName}
   else:
     git worktree add <path> -b {branchName} origin/{defaultBranch}
```

Always branches from latest remote state. Handles both fresh branches and existing ones (feedback loop case).

## Workspace Layout

```
~/.psyduck/
├── plans/
│   └── ENG-123/
│       ├── context.md           # task exported as markdown
│       ├── plan.md              # RFC generated by agent
│       └── repos/               # shallow clones for planning
│           └── owner--repo/
└── worktrees/
    └── ENG-123/
        ├── repo-name-1/         # git worktree
        └── repo-name-2/
```

## Settings

Stored in UserDefaults (matching existing pattern).

- **Linear**: API key.
- **Agents**: List of configured agents (command, default model per agent, ACP native flag). Auto-discovery from PATH.
- **Defaults**: Default planning agent, default building agent.
- **Permissions**: Auto-approve or ask user for each tool call.
- **Directories**: Plans root (`~/.psyduck/plans/`), worktrees root (`~/.psyduck/worktrees/`).
- **Tracked folders**: Existing.

## Agent Prompts

### Planning

Suggested template (agent can deviate):

```
You are a senior software engineer. Write a detailed plan for the following task.

Read the task context at: {context.md path}

Relevant codebase(s) cloned at:
{list of shallow clone paths}

Browse the code, then write a plan covering:
1. Problem statement.
2. Proposed approach.
3. Files/modules to change.
4. New files to create.
5. Testing strategy.
6. Rollout considerations.
7. Open questions.

Write the plan to: {plan.md path}
Be specific about code paths and file references.
```

### Building

```
Implement a feature based on an approved plan.

Plan: {plan.md path}
Task context: {context.md path}
Worktrees: {list of worktree paths}

For each repo:
1. Read the plan.
2. Make changes.
3. Run tests.
4. Commit with descriptive messages.

When done, push and create a draft PR for each repo via:
gh pr create --draft --title "{identifier}: {title}" --body "..."
```

### PR Feedback (Agent button on PR cards)

User provides the prompt via popover. Quick actions:
- "Address review comments" → agent runs `gh pr view --comments`, reads feedback, applies fixes, pushes.
- "Fix CI failures" → agent runs `gh pr checks`, reads failures, fixes, pushes.
- Custom prompt → user writes anything.

## Plan Review

Sheet overlay triggered from Plan column when `planStatus == .readyForReview`.

- Markdown rendered with line numbers.
- Click a line to insert `> **REVIEW**: ...` blockquote below it.
- "Approve" → repo picker (from tracked folders) → move to Build with agent/model picker.
- "Revise" → fresh ACP session with commented plan as context.

Revision prompt: "Revise this plan. Address all `> **REVIEW**:` comments inline. Remove comment blocks after addressing."

## Key Flows

### Task: Triage → Plan → Build → Draft

1. User clicks "Plan" on triage card → popover: pick agent + model (defaults from settings) → Start.
2. `TicketContextService` exports task to `context.md`, shallow-clones relevant repos.
3. ACP session created. Agent generates `plan.md`. UI shows real-time output.
4. Agent finishes → card shows "Ready for Review". User reviews in sheet.
5. If revise: fresh ACP session with comments. If approve: pick repos + agent + model → Build.
6. `TaskWorktreeService` creates worktrees (fetch origin, branch from latest default).
7. ACP session created. Agent codes, pushes, creates draft PRs. Card auto-advances to Draft.

### PR Feedback: Draft/Validation/InReview → Build → back

1. PR card with worktree shows "Agent" button. User clicks it.
2. Popover: pick agent + model, choose quick action or write custom prompt.
3. Card moves to Build temporarily. `PRAgentSession` records return column.
4. ACP session in existing worktree. Agent works, pushes.
5. Card returns to correct PR column based on updated PR state.

### Manual Task Creation

"+" button in Triage column header. Title + description (markdown). Creates `BoardTask` with `linearId: nil`. Full Plan → Build → Draft flow.

## Implementation Phases

### Phase 1: Foundation (~900 LOC)

**New**: `LinearService.swift`, `Views/TaskCard.swift`.
**Modified**: `Package.swift`, `Models.swift`, `BoardViewModel.swift`, `CacheService.swift`, `Views/ContentView.swift`, `Views/KanbanBoard.swift`, `Views/SettingsSheet.swift`.

- `BoardTask` model, `TaskPhase`, `PlanStatus`, `AgentConfig`, `AgentPreferences`.
- `LinearService`: GraphQL fetch → `LinearTicketDTO` → upsert into `[BoardTask]`.
- Settings: Linear API key, agent configs (command + default model per agent), default planning/building agent, permission policy, directories.
- Cache extended for `[BoardTask]`.
- Triage column with Linear-synced + manual tasks. Filter pills for team/project. "+" button for manual task creation.
- Horizontal scroll on `KanbanBoard`.

### Phase 2: ACP + Plan (~1800 LOC)

**New**: `ACPClient.swift`, `ACPTypes.swift`, `AgentRegistry.swift`, `TicketContextService.swift`, `PlanService.swift`, `Views/AgentOutputView.swift`, `Views/PlanReviewView.swift`.
**Modified**: `Package.swift` (add `swift-json-rpc`), `BoardViewModel.swift`, `Views/TaskCard.swift`, `Views/KanbanBoard.swift`.

- `ACPClient`: JSON-RPC 2.0 over stdio. `initialize` handshake, `session/new`, `session/prompt`, `session/update` parsing, `session/request_permission` handling, `session/cancel`, `terminal/*`, `fs/*`.
- `ACPTypes`: All protocol types (`ContentBlock`, `SessionUpdate`, `ToolCall`, `PlanEntry`, `StopReason`, etc.).
- `AgentRegistry`: discover ACP agents on PATH.
- `TicketContextService`: task → `context.md` export + `gh repo clone --depth=1` for planning repos.
- `PlanService`: plan file management, review comment detection.
- Plan column: agent running state with `AgentOutputView`, steering input, auto-advance to "ready for review", plan review sheet with line numbers + blockquote comments, approve (→ Build) / revise (→ re-plan).
- Agent/model picker popover at plan start.

### Phase 3: Build (~1000 LOC)

**New**: `TaskWorktreeService.swift`.
**Modified**: `BoardViewModel.swift`, `GitHubService.swift`, `Views/TaskCard.swift`, `Views/KanbanBoard.swift`.

- `TaskWorktreeService`: `git fetch origin`, detect default branch via `gh api`, create worktrees under `~/.psyduck/worktrees/{identifier}/{repo}/`. Handle existing branches.
- Build column: ACP session in worktrees, real-time output, steering.
- Agent pushes + `gh pr create --draft`. Auto-advance to Draft.
- Agent/model picker popover at build start (with repo selection).

### Phase 4: Agent on PRs (~600 LOC)

**Modified**: `Views/PRCard.swift`, `BoardViewModel.swift`, `Models.swift`.

- "Agent" button on any PR card (Draft/Validation/InReview) that has a detected local worktree.
- Prompt popover: agent/model picker, quick actions ("Address review comments", "Fix CI"), custom prompt field.
- `PRAgentSession` tracks return column. Card moves to Build, agent runs, pushes, card returns.

### Total: ~4300 LOC new. Final app: ~6900 LOC.

## New SPM Dependency

`swift-json-rpc` (or equivalent) for JSON-RPC 2.0 message framing. First and only external dependency.

## File Structure (Final)

```
Sources/
  App.swift
  Models.swift                    # Extended: BoardTask, AgentConfig, etc.
  Theme.swift
  BoardViewModel.swift            # Extended: task management, ACP lifecycle
  CacheService.swift              # Extended: task cache
  GitHubService.swift             # Extended: PR creation, comments, checks
  WorktreeService.swift           # Existing (PR worktree matching)
  LinearService.swift             # NEW
  ACPClient.swift                 # NEW
  ACPTypes.swift                  # NEW
  AgentRegistry.swift             # NEW
  PlanService.swift               # NEW
  TicketContextService.swift      # NEW
  TaskWorktreeService.swift       # NEW
  Views/
    ContentView.swift             # Extended: toolbar, filters, dialogs
    KanbanBoard.swift             # Extended: 8 columns, horizontal scroll
    PRCard.swift                  # Extended: Agent button
    SettingsSheet.swift           # Extended: Linear, agents, models, dirs
    TaskCard.swift                # NEW
    AgentOutputView.swift         # NEW
    PlanReviewView.swift          # NEW
```

## References

- [ACP (Agent Client Protocol)](https://agentclientprotocol.com) — JSON-RPC protocol for editor↔agent communication. PsyDuck implements the client side.
- [ACP Agents List](https://agentclientprotocol.com/get-started/agents) — 30+ compatible agents.
- [Jockey](https://github.com/recailai/jockey) — Tauri/Rust/SolidJS ACP orchestrator (prior art for multi-agent desktop app).
- [OpenAI Harness Engineering](https://openai.com/index/harness-engineering/) — Agent-first development patterns.
- [OpenAI Symphony](https://github.com/openai/symphony) — Issue tracker as agent control plane, workspace isolation.
