# PsyDuck

Native macOS Kanban board for your GitHub PRs. Built with SwiftUI, powered by the `gh` CLI.

## Requirements

- macOS 15+.
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated.
- Swift 6+ to build from source.

## Install

```bash
./scripts/build.sh   # builds, installs to /Applications, creates dist/PsyDuck.dmg
./scripts/dev.sh     # run in debug mode
```

## Columns

**Draft** | **Validation** | **Waiting for Review** | **Approved** | **Merged**

- **Validation**: approved but blocked — CI Running (amber), CI Failed (red), Merge Conflicts (red), Behind Base (amber). Only required checks matter.
- **Approved**: review approved, CI green, no conflicts. Ready to merge.
- **Merged**: only shows PRs with a local worktree (for cleanup).

## Features

- Multi-select organization and repository filters.
- Local worktree tracking via settings (gear icon). Matches worktrees to PRs by branch.
- **Open in...** menu: Zed, VS Code, IntelliJ, Ghostty, Finder. Auto-detects installed apps via PATH.
- **PR actions**: Squash & Merge (with strategy dropdown), Ready for Review, Update Branch, Close PR (X on hover), Delete Worktree.
- Copy PR link to clipboard (link icon on each card).
- Disk cache for instant launch. Auto-refresh every 5 minutes, manual with `Cmd+R`.
- Friendly setup error if `gh` is not installed or not authenticated.
