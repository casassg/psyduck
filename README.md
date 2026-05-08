# gh-prs

A native macOS app that shows your GitHub PRs in a Kanban board. Built with SwiftUI, powered by the `gh` CLI.

## Features

- **5-column Kanban board**: Draft, In Review, Validation, Approved, Merged.
- **Validation column** detects approved PRs blocked by CI failures (red), running CI (amber), merge conflicts (red), or behind base (amber). Uses `gh pr checks --required` so only required checks matter.
- **Approved = ready to merge**: only PRs with green CI and no conflicts.
- **Merged column** only shows PRs that have a matching local worktree (for cleanup).
- **Filter by organization and/or repository** with pill-shaped dropdowns.
- **Local worktree tracking**: add folders (e.g. `~/Development`) via settings. The app scans for git repos, matches worktrees to PRs by branch name.
- **Open in...** menu on worktree PRs: Zed, VS Code, IntelliJ, Ghostty, Finder. Only shows apps found on your PATH.
- **PR actions**:
  - **Squash & Merge** (with dropdown for merge commit / rebase) on approved PRs.
  - **Update Branch** (rebase) on behind-base PRs.
  - **Close PR** (X button, top-right on hover) with branch deletion.
  - **Delete Worktree** on merged PRs (skips main worktree).
- **Auto-refresh** every 5 minutes. Manual refresh with the button or `Cmd+R`.
- **Raycast-inspired dark UI**: dark surfaces, accent-colored cards, hover glow, pointer cursors.

## Requirements

- macOS 15+.
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated.
- Swift 6+ (comes with Xcode 16+).

## Quick Start

```bash
# Run in debug mode
./scripts/dev.sh

# Build release .app bundle
./scripts/build.sh

# Install
cp -r "dist/GH PRs.app" /Applications/
```

## Usage

1. Launch the app. It fetches your PRs automatically.
2. Click the gear icon to add tracked folders (e.g. `~/Development`).
3. PRs with matching local worktrees show an **Open** button.
4. Hover a card to reveal the **X** close button (top-right).
5. Use **Squash & Merge** on approved PRs or **Update Branch** on behind PRs.
6. Clean up stale worktrees from the Merged column.

## How It Works

1. `gh search prs --author @me` finds all your open + recently merged PRs.
2. `gh pr view` enriches each PR with review decision, merge state, diff stats.
3. `gh pr checks --required` detects required CI status (pass/fail/pending).
4. `git worktree list --porcelain` + `git remote get-url origin` maps local worktrees to PRs.
5. PRs are classified into columns based on review + CI + merge state.
