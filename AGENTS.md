# gh-prs

Native macOS SwiftUI app. Kanban board for GitHub PRs with local worktree tracking.

## Tech Stack

- Swift 6 / SwiftUI, macOS 15+.
- Swift Package Manager, single executable target.
- No external dependencies. Uses `gh` CLI and `git` via `Process`.

## Architecture

```
Sources/
  App.swift              # @main entry, window config
  Models.swift           # PullRequest, KanbanColumn, ValidationStatus, Worktree, OpenInApp, MergeStrategy
  Theme.swift            # Raycast-style dark palette, typography, spacing tokens, .pointingHand() modifier
  GitHubService.swift    # Wraps gh CLI: search, view, checks, merge, close, update-branch
  WorktreeService.swift  # Scans tracked folders for git repos, discovers worktrees via porcelain format
  BoardViewModel.swift   # @Observable @MainActor. State, filters, auto-refresh timer, PR actions
  Views/
    ContentView.swift    # Toolbar, filter pills, confirmation dialogs, settings sheet trigger
    KanbanBoard.swift    # HStack of 5 ColumnViews
    PRCard.swift         # Card with hover, X close, validation badge, Open/Merge/Update/Delete buttons
    SettingsSheet.swift  # NSOpenPanel folder picker, tracked folders list
```

## Key Design Decisions

- `gh search prs` for cross-repo discovery, `gh pr view` + `gh pr checks --required` for enrichment (parallel).
- Worktree matching: `git remote get-url origin` → extract owner/repo, `git worktree list --porcelain` → branch map.
- Optimistic UI removal after close/merge (GitHub search index lags).
- Confirmation alert race fix: button closures capture action synchronously before alert dismiss clears pendingAction.
- OpenInApp detection via `which` on PATH, not hardcoded binary paths.

## Columns

Draft | In Review | Validation | Approved | Merged (worktree-only).

Validation = approved but blocked: CI Running (amber), CI Failed (red), Merge Conflicts (red), Behind Base (amber).
Approved = `reviewDecision == APPROVED` AND `mergeStateStatus == CLEAN` AND no failed required checks.

## Build & Run

```
./scripts/dev.sh      # debug
./scripts/build.sh    # release .app bundle in dist/
```
