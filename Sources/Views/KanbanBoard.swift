import SwiftUI

struct KanbanBoard: View {
    let viewModel: BoardViewModel

    var body: some View {
        HStack(spacing: Theme.columnSpacing) {
            ForEach(KanbanColumn.allCases) { column in
                ColumnView(
                    column: column,
                    prs: viewModel.prs(for: column),
                    viewModel: viewModel
                )
            }
        }
        .padding(Theme.columnSpacing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Column

struct ColumnView: View {
    let column: KanbanColumn
    let prs: [PullRequest]
    let viewModel: BoardViewModel

    var body: some View {
        VStack(spacing: 0) {
            columnHeader
                .padding(.horizontal, Theme.columnPadding)
                .padding(.top, Theme.columnPadding)
                .padding(.bottom, 8)

            if prs.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: Theme.cardSpacing) {
                        ForEach(prs, id: \.id) { pr in
                            PRCard(
                                pr: pr,
                                accentColor: column.accentColor,
                                availableApps: viewModel.availableApps,
                                onMerge: { strategy in
                                    viewModel.confirmMerge(pr, strategy: strategy)
                                },
                                onClose: { viewModel.confirmClose(pr) },
                                onPublish: { viewModel.confirmPublish(pr) },
                                onUpdateBranch: { viewModel.confirmUpdateBranch(pr) },
                                onDeleteWorktree: { viewModel.confirmDeleteWorktree(pr) }
                            )
                            .transition(.opacity.combined(with: .scale(0.97)))
                        }
                    }
                    .padding(.horizontal, Theme.columnPadding)
                    .padding(.bottom, Theme.columnPadding)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.surfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.columnCornerRadius))
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(column.accentColor)
                .frame(width: 8, height: 8)

            Text(column.rawValue.uppercased())
                .font(Theme.columnHeaderFont)
                .foregroundStyle(Theme.textSecondary)
                .tracking(0.8)

            Spacer()

            Text("\(prs.count)")
                .font(Theme.countBadgeFont)
                .foregroundStyle(column.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(column.accentColor.opacity(0.15))
                .clipShape(Capsule())
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: column.iconName)
                .font(.system(size: 24))
                .foregroundStyle(Theme.textTertiary)
            Text(column.emptyMessage)
                .font(Theme.metaFont)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
