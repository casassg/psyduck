# RFC 001: Agent-Orchestrated Task Pipeline

**Status**: Draft
**Date**: 2026-05-11
**Author**: gerardc (AI-assisted)

## Summary

Extend PsyDuck from a GitHub PR kanban board into a full task-lifecycle tool by adding four new columns—Triage, Planning, Ready, Building—that bridge Linear tickets to agent-generated code and draft PRs. Inspired by [OpenAI Harness Engineering](https://openai.com/index/harness-engineering/) and [Symphony](https://github.com/openai/symphony).

## Motivation

The current app tracks PRs after they exist. The gap is everything before: triaging a ticket, designing a solution, writing the code, and creating the PR. This RFC fills that gap by integrating Linear as the work source and headless coding agents as the execution engine, with human review at every handoff.

## Column Flow

```
Triage → Planning → Ready → Building → Draft → Validation → In Review → Approved → Merged
            ↑                   ↑         │
            └── Ready (revise) ─┘         │
                                          └── Building (apply feedback) ─┘
```

- **Triage**: Linear tickets created by or assigned to the user. Entry point.
- **Planning**: AI agent generates an RFC/plan document from ticket context. Steerable.
- **Ready**: Human reviews plan. Approve (select repos) or revise (add inline comments → back to Planning).
- **Building**: Agent codes in isolated worktrees. Creates draft PR on completion → enters existing Draft column.
- **Draft → Building loop**: "Review Feedback" button reads GH comments + CI, sends agent back to fix.

## Architecture

### Data Models

#### LinearTicket

```swift
struct LinearTicket: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let identifier: String          // "ENG-123"
    let title: String
    let description: String?
    let priority: Int?              // 1=urgent, 2=high, 3=medium, 4=low
    let state: String
    let assignee: String?
    let creator: String?
    let labels: [String]
    let url: String?
    let branchName: String?
    let comments: [TicketComment]   // all ticket comments
    let createdAt: Date
    let updatedAt: Date
}

struct TicketComment: Equatable, Sendable, Codable {
    let author: String
    let body: String
    let createdAt: Date
}
```

#### PsyDuckTask

The central model for items flowing through Triage → Building.

```swift
struct PsyDuckTask: Identifiable, Equatable, Sendable, Codable {
    let id: String                      // derived from ticket.id
    var ticket: LinearTicket
    var phase: TaskPhase
    var planPath: URL?                  // path to plan.md on disk
    var selectedRepos: [String]?        // repo full names for building
    var worktrees: [TaskWorktree]?      // created worktrees
    var agentType: AgentType
    var pokemonName: String?            // workspace folder name
    var draftPRNumbers: [PRRef]?        // created draft PR references
    var createdAt: Date
    var updatedAt: Date
}

enum TaskPhase: String, Codable, CaseIterable {
    case triage
    case planning
    case ready
    case building
}

struct TaskWorktree: Equatable, Sendable, Codable {
    let repoFullName: String            // "owner/repo"
    let branch: String
    let path: String                    // absolute path to worktree
}

struct PRRef: Equatable, Sendable, Codable {
    let repoFullName: String
    let number: Int
    let url: String
}

enum AgentType: String, CaseIterable, Identifiable, Codable, Sendable {
    case opencode
    case claudeCode
    case codex
    case amp
    case aider

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opencode: "OpenCode"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .amp: "Amp"
        case .aider: "Aider"
        }
    }
}
```

#### AgentEvent (parsed from JSON stream)

```swift
enum AgentEvent: Sendable {
    case thinking(text: String)
    case readingFile(path: String)
    case writingFile(path: String)
    case runningCommand(command: String)
    case commandOutput(text: String)
    case message(text: String)
    case error(text: String)
    case completed
    case unknown(raw: String)
}
```

### New Services

#### LinearService

Wraps the Linear GraphQL API using the user's personal API key.

```swift
final class LinearService: Sendable {
    /// Fetch tickets created by or assigned to the authenticated user.
    /// Ordered by updatedAt descending. Uses Personal API key from settings.
    func fetchMyTickets(apiKey: String) async throws -> [LinearTicket]

    /// Fetch a single ticket with full details (comments, links, relations).
    func fetchTicket(id: String, apiKey: String) async throws -> LinearTicket
}
```

Implementation approach:
- Direct HTTPS requests to `https://api.linear.app/graphql` using `URLSession`.
- GraphQL query filters: `assignedTo: me OR createdBy: me`, non-terminal states.
- Parse JSON response into `LinearTicket` structs.
- No `gh` CLI dependency—Linear has no CLI we'd use.

#### AgentService

Manages agent process lifecycle. Launches headless agents, streams JSON output, supports steering.

```swift
@Observable @MainActor
final class AgentService {
    /// Active agent runs keyed by task ID.
    private(set) var activeRuns: [String: AgentRun] = [:]

    /// Launch an agent for planning or building.
    func launch(taskId: String, agent: AgentType, prompt: String,
                workingDir: URL, contextFiles: [URL]) -> AgentRun

    /// Send a steering message to a running agent.
    func steer(taskId: String, message: String)

    /// Kill a running agent.
    func kill(taskId: String)
}

@Observable
final class AgentRun: Identifiable {
    let id: String
    let process: Process
    var events: [AgentEvent] = []
    var isRunning: Bool = true
    var exitCode: Int32?
}
```

Agent execution via Swift `Process` + `Pipe`:
- Each agent adapter builds the correct CLI command.
- stdout pipe reads JSON/JSONL lines, parsed into `AgentEvent`.
- stdin pipe allows writing steering messages.
- Process termination signals completion.

#### AgentAdapter Protocol

```swift
protocol AgentAdapter: Sendable {
    var agentType: AgentType { get }

    /// CLI command + args for planning mode.
    func planCommand(prompt: String, workDir: URL, contextFiles: [URL]) -> ProcessConfig

    /// CLI command + args for building mode.
    func buildCommand(prompt: String, workDir: URL, contextFiles: [URL]) -> ProcessConfig

    /// Parse one line of stdout into a structured event.
    func parseEvent(line: String) -> AgentEvent?

    /// Format a steering message for stdin.
    func formatSteering(message: String) -> String
}

struct ProcessConfig: Sendable {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL
}
```

Adapter implementations per agent:

| Agent | Plan command | Build command | JSON flag | Steering |
|-------|-------------|---------------|-----------|----------|
| OpenCode | `opencode run --dir {dir} --format json -f {ctx} "…"` | same | `--format json` | stdin newline |
| Claude Code | `claude -p "…" --output-format stream-json --bare` | same + `--allowedTools` | `--output-format stream-json` | not supported in `-p` mode; use `--resume` |
| Codex | `codex exec --cd {dir} --json "…"` | same + `--sandbox workspace-write` | `--json` | stdin |
| Amp | `amp -x "…" --stream-json` | same + `--dangerously-allow-all` | `--stream-json` | not supported in `-x` |
| Aider | `aider -m "…" --yes {files}` | same | no native JSON | not supported |

Note: Steering (sending follow-up prompts mid-run) is limited by agent capabilities. OpenCode and Codex support it via stdin. Claude Code and Amp require stopping and resuming with `--resume`/`threads continue`. For agents that don't support live steering, the UI should show "Stop & Redirect" instead of inline steering.

#### TicketContextService

Exports a Linear ticket to a self-contained markdown file the agent can read.

```swift
struct TicketContextService: Sendable {
    /// Export a ticket to a markdown file at the given directory.
    /// Returns the path to the created context.md file.
    func exportTicket(_ ticket: LinearTicket, to directory: URL) throws -> URL
}
```

Output format (`context.md`):

```markdown
# {identifier}: {title}

**Priority**: {priority} | **State**: {state} | **Assignee**: {assignee}
**Labels**: {labels} | **Created**: {createdAt} | **Updated**: {updatedAt}
**URL**: {url}

## Description

{full markdown description}

## Comments

### @{author} ({date})
{comment body}

## Links
- {extracted URLs from description and comments}

## Relations
- Blocks: {related tickets}
- Blocked by: {blocking tickets}
```

#### PlanService

Manages plan files on disk under `~/.psyduck/plans/`.

```swift
struct PlanService: Sendable {
    let plansRoot: URL  // ~/.psyduck/plans/

    /// Get or create the plan directory for a task.
    func planDirectory(for taskId: String, identifier: String) -> URL

    /// Read the plan markdown file.
    func readPlan(at path: URL) throws -> String

    /// Check if a plan has inline review comments.
    func hasReviewComments(at path: URL) throws -> Bool

    /// Strip review comments from a plan (for agent re-read).
    func stripComments(from plan: String) -> String
}
```

Plan review comments use inline markdown blockquotes:

```markdown
## Authentication Flow

The service should use OAuth2 with PKCE for the auth flow...

> **REVIEW**: Have we considered using the existing auth middleware
> from the shared-auth package? That would save us from reimplementing
> token refresh. — gerardc

The token refresh logic will handle...
```

When the plan is sent back to Planning, the agent receives:
1. The plan with comments still in it (so it can see what was said where).
2. A prompt: "Revise this plan. Address all `> **REVIEW**:` comments inline. Remove the comment blocks after addressing them."

#### TaskWorktreeService

Creates and manages worktrees under `~/.psyduck/worktrees/`.

```swift
final class TaskWorktreeService: Sendable {
    let worktreeRoot: URL  // ~/.psyduck/worktrees/

    /// Create worktrees for a task. One per selected repo.
    /// Returns the pokemon name and worktree paths.
    func createWorktrees(
        taskId: String,
        repos: [(fullName: String, localPath: URL)],
        branchName: String
    ) async throws -> (pokemonName: String, worktrees: [TaskWorktree])

    /// Remove worktrees for a task.
    func removeWorktrees(pokemonName: String) async throws

    /// List existing worktrees under the root.
    func listWorktrees() throws -> [String]  // pokemon names
}
```

Worktree creation steps:
1. Pick pokemon name from embedded list (hash of task ID, collision-resistant).
2. Create `~/.psyduck/worktrees/{pokemon}/`.
3. For each repo: `git worktree add {pokemon}/{repo-name} -b {branch}` from the repo's main checkout.
4. Return paths for agent to work in.

Pokemon name list: embed Gen 1 names (bulbasaur through mew, 151 names). Derive index from `taskId.hashValue % 151`. On collision with existing worktrees, append `-2`, `-3`, etc.

### Workspace Layout

```
~/.psyduck/
├── plans/
│   └── ENG-123/
│       ├── context.md           # Linear ticket as markdown (input for agent)
│       ├── plan.md              # RFC generated by agent (output)
│       └── repos/               # Shallow clones for planning
│           ├── owner--repo-1/
│           └── owner--repo-2/
├── worktrees/
│   └── bulbasaur/               # Pokemon name per task
│       ├── repo-name-1/         # git worktree
│       └── repo-name-2/         # git worktree
└── agents.md                    # Optional: shared agent instructions
```

### Settings Expansion

Current settings: `trackedFolders: [String]` in UserDefaults.

New settings stored in UserDefaults:

```swift
// Keys
"linearApiKey"          // String — Linear Personal API key
"defaultAgentType"      // String — AgentType raw value
"plansDirectory"        // String — custom plans root (default ~/.psyduck/plans/)
"worktreeDirectory"     // String — custom worktree root (default ~/.psyduck/worktrees/)
```

The SettingsSheet gets new sections:
1. **Linear Integration**: API key text field with paste support.
2. **Agent Configuration**: Picker for default agent. Per-agent binary path overrides (optional).
3. **Directories**: Plan storage and worktree root paths.

### BoardViewModel Changes

The ViewModel currently manages only `[PullRequest]`. It needs to also manage `[PsyDuckTask]`.

```swift
@Observable @MainActor
final class BoardViewModel {
    // Existing
    var pullRequests: [PullRequest] = []

    // New
    var tasks: [PsyDuckTask] = []
    var linearTickets: [LinearTicket] = []  // raw tickets for triage

    // Computed: board items per column
    var triageItems: [LinearTicket] { ... }
    var planningItems: [PsyDuckTask] { ... }
    var readyItems: [PsyDuckTask] { ... }
    var buildingItems: [PsyDuckTask] { ... }
    // Existing PR columns stay the same

    // Actions
    func startPlanning(ticket: LinearTicket, agent: AgentType) async { ... }
    func approvePlan(task: PsyDuckTask, repos: [String]) async { ... }
    func revisePlan(task: PsyDuckTask) async { ... }
    func reviewFeedback(pr: PullRequest) async { ... }
}
```

Refresh cycle change:
- Existing: fetch PRs → enrich → match worktrees → update UI.
- New: also fetch Linear tickets → update `linearTickets` → update task phases.
- Cache both PRs and tasks.

### KanbanBoard Changes

Currently renders 5 `ColumnView`s from `KanbanColumn.allCases`. Needs to render 9 columns.

The existing `KanbanColumn` enum expands:

```swift
enum KanbanColumn: String, CaseIterable, Identifiable {
    case triage
    case planning
    case ready
    case building
    case draft
    case validation
    case inReview
    case approved
    case merged
}
```

Each column renders either `PRCard` (for PR-based columns) or a new `TaskCard` (for task-based columns) or both (Draft column can have both PRs and tasks that just created draft PRs).

### New Views

#### TaskCard

Similar to `PRCard` but for `PsyDuckTask` / `LinearTicket`:

```
┌─────────────────────────────┐
│ ENG-123                 ▼ P2│
│ Implement OAuth2 flow       │
│ backend, auth               │
│ Updated 2h ago              │
│                             │
│ [Plan ▶]  or  [View Plan]  │
│          or  [Building...]  │
└─────────────────────────────┘
```

Buttons vary by phase:
- **Triage**: "Plan" button (pick agent, start planning).
- **Planning**: Shows agent progress. "Stop" button. Steering input.
- **Ready**: "View Plan" button. "Approve" / "Revise" buttons.
- **Building**: Shows agent progress. "Stop" button. Steering input.

#### AgentOutputView

Expandable panel that shows real-time agent events:

```
┌─────────────────────────────┐
│ 🔍 Reading src/auth.ts      │
│ 💭 Analyzing OAuth2 flow... │
│ 📝 Writing plan section 3   │
│ ⚡ Running: npm test         │
│ ✅ Tests passed              │
│                             │
│ [Send message...        ] ▶ │
└─────────────────────────────┘
```

- Scrollable, auto-scrolls to bottom.
- Each event type gets an icon and formatting.
- Steering input field at bottom.
- Expand/collapse per card.

#### PlanReviewView

Sheet/panel for reviewing a plan in the Ready column:

```
┌──────────────────────────────────────┐
│ Plan: ENG-123 — Implement OAuth2     │
├──────────────────────────────────────┤
│  1│ # Authentication Design          │
│  2│                                  │
│  3│ ## Approach                      │
│  4│ Use OAuth2 with PKCE...    [💬]  │
│  5│                                  │
│  6│ > **REVIEW**: Consider reusing   │
│  7│ > shared-auth middleware.        │
│  8│                                  │
│  9│ ## Implementation Steps          │
│ 10│ 1. Add auth middleware...        │
├──────────────────────────────────────┤
│ [Approve & Select Repos]  [Revise]  │
└──────────────────────────────────────┘
```

- Markdown rendered with line numbers.
- Click [💬] on any line to insert a `> **REVIEW**: ...` block below it.
- "Approve" opens repo picker (from tracked repos).
- "Revise" sends back to Planning with comments as context.

#### RepoPickerSheet

Shown when approving a plan. Lets user select which repos the building phase should target:

```
┌──────────────────────────────────┐
│ Select repos for building        │
│                                  │
│ ☑ owner/api-server               │
│ ☐ owner/web-client               │
│ ☑ owner/shared-lib               │
│                                  │
│ [Start Building]                 │
└──────────────────────────────────┘
```

Repos come from the tracked folders that PsyDuck already scans.

### Agent Prompt Templates

#### Planning Prompt

```
You are a senior software engineer. Your task is to write a detailed
RFC/plan document for the following Linear ticket.

Read the ticket context file at: {context.md path}

You have access to the relevant codebase(s) cloned at:
{list of repo clone paths}

Browse the code to understand the current architecture, then write
a comprehensive plan that covers:
1. Problem statement (from the ticket).
2. Proposed solution with technical approach.
3. Files/modules that need to change.
4. New files/modules to create.
5. Testing strategy.
6. Rollout considerations.
7. Open questions.

Write the plan as a markdown file at: {plan.md path}

Be specific about code paths, function names, and module boundaries.
Reference actual files in the codebase.
```

#### Building Prompt

```
You are implementing a feature based on an approved plan.

Plan: {plan.md path}
Ticket context: {context.md path}

You are working in these worktrees:
{list of worktree paths with repo names}

Implement the plan. For each repo:
1. Read the plan carefully.
2. Make the code changes described.
3. Run existing tests to verify nothing breaks.
4. Add new tests as specified in the plan.
5. Commit your changes with descriptive messages.

When done with all changes, use `gh pr create --draft` to create
a draft PR for each repo. Include the ticket identifier ({identifier})
in the PR title.
```

#### Feedback Prompt

```
Your draft PR has received review feedback. Address the comments
and fix any CI failures.

PR: {pr URL}
Worktree: {worktree path}

1. Read the PR review comments: `gh pr view {number} --comments`
2. Check CI status: `gh pr checks {number}`
3. Address each comment and fix any failing checks.
4. Commit and push your changes.
```

### Caching

Extend `CacheService` to also cache:
- `LinearTicket` list (same pattern as PR cache).
- `PsyDuckTask` list (persists task state across app restarts).

```swift
struct CachedData: Sendable, Codable {
    let pullRequests: [PullRequest]
    let linearTickets: [LinearTicket]    // new
    let tasks: [PsyDuckTask]            // new
    let lastRefresh: Date
}
```

### Repo Cloning for Planning

When a task enters Planning, `TicketContextService` also handles repo cloning:

1. User selects which repos are relevant (or auto-detect from ticket labels/description).
2. For each repo: `gh repo clone {fullName} {plans/ENG-123/repos/owner--repo} -- --depth=1`.
3. Shallow clone keeps disk usage low.
4. Clone path is passed to the agent as context.
5. After planning completes, clones can be optionally cleaned up (or kept for revision cycles).

## Implementation Phases

### Phase 1: Foundation (~800 LOC)

New/modified files:
- `Models.swift`: Add `LinearTicket`, `PsyDuckTask`, `TaskPhase`, `AgentType`, and related types.
- `LinearService.swift` (new): GraphQL client for Linear API.
- `CacheService.swift`: Extend to cache tickets and tasks.
- `SettingsSheet.swift`: Add Linear API key field, agent picker, directory settings.
- `BoardViewModel.swift`: Add `tasks`, `linearTickets`, fetch in refresh cycle.
- `KanbanBoard.swift`: Add Triage column, render `LinearTicket` cards.
- `Views/TaskCard.swift` (new): Card view for tasks/tickets.

Deliverable: Triage column shows Linear tickets. Settings has Linear API key.

### Phase 2: Planning Pipeline (~1200 LOC)

New/modified files:
- `AgentAdapter.swift` (new): Protocol + adapters for all 5 agents.
- `AgentService.swift` (new): Process management, JSON streaming.
- `TicketContextService.swift` (new): Ticket → markdown export + repo cloning.
- `PlanService.swift` (new): Plan file management.
- `Views/AgentOutputView.swift` (new): Real-time event log view.
- `Views/TaskCard.swift`: Add planning state with agent output.
- `BoardViewModel.swift`: Add `startPlanning()`, agent lifecycle.

Deliverable: "Plan" button on triage cards launches agent, shows progress, generates plan.md.

### Phase 3: Plan Review (~600 LOC)

New/modified files:
- `Views/PlanReviewView.swift` (new): Markdown viewer with line numbers and comment insertion.
- `Views/RepoPickerSheet.swift` (new): Repo selection for building.
- `Views/TaskCard.swift`: Add ready state with view/approve/revise buttons.
- `BoardViewModel.swift`: Add `approvePlan()`, `revisePlan()`.
- `PlanService.swift`: Add comment detection, stripping.

Deliverable: Ready column with plan review, inline comments, approve/revise flow.

### Phase 4: Building Pipeline (~1000 LOC)

New/modified files:
- `TaskWorktreeService.swift` (new): Worktree creation under `~/.psyduck/worktrees/`.
- `PokemonNames.swift` (new): Embedded name list + deterministic picker.
- `Views/TaskCard.swift`: Add building state with agent output.
- `BoardViewModel.swift`: Add building lifecycle, draft PR creation.
- `GitHubService.swift`: Add `createDraftPR()`, `fetchPRComments()`, `fetchPRChecks()`.

Deliverable: Approved plans → worktrees created → agent builds → draft PR created → enters Draft column.

### Phase 5: Feedback Loop (~400 LOC)

New/modified files:
- `Views/PRCard.swift`: Add "Review Feedback" button for draft PRs with associated tasks.
- `BoardViewModel.swift`: Add `reviewFeedback()` action.
- `GitHubService.swift`: Add `fetchReviewComments()`.

Deliverable: "Review Feedback" on Draft cards → agent reads comments/CI → fixes → pushes → card moves to correct column.

### Estimated Total: ~4000 LOC new code

Current codebase: ~2600 LOC. Final: ~6600 LOC.

## File Structure (Final)

```
Sources/
  App.swift
  Models.swift                    # Extended with new types
  Theme.swift
  BoardViewModel.swift            # Extended with task management
  CacheService.swift              # Extended with task/ticket cache
  GitHubService.swift             # Extended with PR creation/comments
  WorktreeService.swift           # Existing (PR worktree matching)
  LinearService.swift             # NEW
  AgentService.swift              # NEW
  AgentAdapter.swift              # NEW (protocol + 5 adapters)
  PlanService.swift               # NEW
  TicketContextService.swift      # NEW
  TaskWorktreeService.swift       # NEW
  PokemonNames.swift              # NEW
  Views/
    ContentView.swift             # Extended with new column UI
    KanbanBoard.swift             # Extended to 9 columns
    PRCard.swift                  # Extended with feedback button
    SettingsSheet.swift           # Extended with Linear/agent settings
    TaskCard.swift                # NEW
    AgentOutputView.swift         # NEW
    PlanReviewView.swift          # NEW
    RepoPickerSheet.swift         # NEW
```

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Agent CLI interfaces change | Adapter pattern isolates changes to one file per agent. |
| Linear API rate limits | Cache aggressively. Personal API key has generous limits. |
| Agent runs take very long | Show real-time progress. Allow kill/restart. Timeout after configurable duration. |
| Worktree disk usage | Pokemon-named folders are easy to identify. Add cleanup in settings. |
| Steering not supported by all agents | UI adapts per agent: show "Stop & Redirect" instead of inline steering for non-supporting agents. |
| Plan review UX complexity | Start simple (raw markdown + blockquote comments). Improve iteratively. |

## Open Questions

1. Should the Triage column filter by Linear project/team, or show all tickets assigned to/created by the user?
2. For multi-repo tasks, should the agent get all worktrees in one session, or separate sessions per repo?
3. Should we auto-detect relevant repos from the ticket (by labels, project, mentioned repo names), or always require manual selection?
4. What's the maximum concurrent agent count? (System resources are the bottleneck.)
5. Should plan.md follow a specific template structure, or let the agent decide?

## References

- [OpenAI Harness Engineering](https://openai.com/index/harness-engineering/) — Lessons on agent-first development, repo knowledge, feedback loops.
- [OpenAI Symphony](https://github.com/openai/symphony) — Issue tracker as agent control plane, SPEC.md approach, workspace isolation.
- [Symphony SPEC.md](https://github.com/openai/symphony/blob/main/SPEC.md) — Detailed orchestration specification.
- [ACP / A2A](https://agentcommunicationprotocol.dev) — Agent interop protocol (evaluated, not adopted; headless CLI is simpler for our use case).
