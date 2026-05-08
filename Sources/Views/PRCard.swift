import SwiftUI

struct PRCard: View {
    let pr: PullRequest
    let accentColor: Color
    let availableApps: [OpenInApp]
    let onMerge: (MergeStrategy) -> Void
    let onClose: () -> Void
    let onPublish: () -> Void
    let onUpdateBranch: () -> Void
    let onDeleteWorktree: () -> Void

    @State private var isHovered = false
    @State private var copied = false

    private var isOpen: Bool {
        pr.column != .merged
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            cardContent

            if isOpen && isHovered {
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 18, height: 18)
                        .background(Theme.surfaceBackground, in: Circle())
                        .overlay(Circle().stroke(Theme.cardBorder, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .pointingHand()
                .help("Close PR & delete branch")
                .padding(6)
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    // MARK: - Card Content

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Repo name
            Text(pr.repoFullName)
                .font(Theme.repoFont)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)

            // Title — clickable to open PR in browser
            Text(pr.title)
                .font(Theme.titleFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .pointingHand()
                .onTapGesture {
                    if let url = URL(string: pr.url) {
                        NSWorkspace.shared.open(url)
                    }
                }

            Spacer().frame(height: 2)

            // PR number + branch + copy link
            HStack(spacing: 6) {
                Text("#\(pr.number)")
                    .font(Theme.metaMonoFont)
                    .foregroundStyle(accentColor)

                if let branch = pr.headRefName {
                    Text(branch)
                        .font(Theme.metaMonoFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                // Copy link button
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pr.url, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "link")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(copied ? Theme.approvedAccent : Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .pointingHand()
                .help("Copy PR link")
                .animation(.snappy(duration: 0.15), value: copied)
            }

            // Validation status badge (only in Validation column)
            if pr.column == .validation {
                validationBadge
            }

            // Stats row: time + diff stats + comments
            HStack(spacing: 0) {
                Text(relativeTime(pr.updatedAt))
                    .font(Theme.metaFont)
                    .foregroundStyle(Theme.textTertiary)

                Spacer()

                if let additions = pr.additions, let deletions = pr.deletions {
                    HStack(spacing: 6) {
                        Text("+\(additions)")
                            .font(Theme.metaMonoFont)
                            .foregroundStyle(Theme.diffAddition)
                        Text("-\(deletions)")
                            .font(Theme.metaMonoFont)
                            .foregroundStyle(Theme.diffDeletion)
                    }
                }

                if pr.commentsCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 9))
                        Text("\(pr.commentsCount)")
                            .font(Theme.metaMonoFont)
                    }
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 8)
                }
            }

            // Action buttons row
            actionRow
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .fill(isHovered ? Theme.cardBackgroundHover : Theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .stroke(
                    isHovered ? accentColor.opacity(0.3) : Theme.cardBorder,
                    lineWidth: 0.5
                )
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
    }

    // MARK: - Validation Badge

    private var validationBadge: some View {
        let status = pr.validationStatus
        return HStack(spacing: 5) {
            Image(systemName: status.icon)
                .font(.system(size: 9))
            Text(status.label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(status.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.12), in: Capsule())
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionRow: some View {
        let column = pr.column
        let hasWorktree = pr.worktree != nil
        let canDeleteWorktree = hasWorktree && !(pr.worktree?.isMain ?? true)
        let showMerge = column == .approved
        let showPublish = column == .draft
        let showUpdate = column == .validation && pr.validationStatus == .behind
        let showDelete = column == .merged && canDeleteWorktree
        let showActions = hasWorktree || showMerge || showPublish || showUpdate || showDelete

        if showActions {
            Divider().opacity(0.1).padding(.vertical, 2)

            HStack(spacing: 6) {
                Spacer()

                if hasWorktree {
                    openButton
                }

                if showPublish {
                    publishButton
                }

                if showUpdate {
                    updateBranchButton
                }

                if showMerge {
                    mergeButton
                }

                if showDelete {
                    deleteWorktreeButton
                }
            }
        }
    }

    // MARK: - Open In Button

    private var openButton: some View {
        Menu {
            if let wt = pr.worktree {
                Text(wt.displayPath)
                Divider()
                ForEach(availableApps) { app in
                    Button {
                        app.open(path: wt.path)
                    } label: {
                        Label(app.name, systemImage: app.icon)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10))
                Text("Open")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.surfaceBackground, in: Capsule())
            .overlay(Capsule().stroke(Theme.cardBorder, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .pointingHand()
    }

    // MARK: - Publish Button

    private var publishButton: some View {
        Button { onPublish() } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 10))
                Text("Ready for Review")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.validationAccent.opacity(0.8), in: Capsule())
        }
        .buttonStyle(.plain)
        .pointingHand()
    }

    // MARK: - Update Branch Button

    private var updateBranchButton: some View {
        Button { onUpdateBranch() } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 10))
                Text("Update Branch")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.inReviewAccent.opacity(0.8), in: Capsule())
        }
        .buttonStyle(.plain)
        .pointingHand()
    }

    // MARK: - Merge Button

    private var mergeButton: some View {
        HStack(spacing: 0) {
            Button {
                onMerge(.squash)
            } label: {
                Text("Squash & Merge")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(MergeStrategy.allCases) { strategy in
                    Button(strategy.rawValue) { onMerge(strategy) }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
        }
        .background(Theme.approvedAccent.opacity(0.8), in: Capsule())
        .pointingHand()
    }

    // MARK: - Delete Worktree Button

    private var deleteWorktreeButton: some View {
        Button { onDeleteWorktree() } label: {
            HStack(spacing: 4) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                Text("Delete Worktree")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Theme.diffDeletion)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.diffDeletion.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(Theme.diffDeletion.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .pointingHand()
    }
}

// MARK: - Helpers

private func relativeTime(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}
