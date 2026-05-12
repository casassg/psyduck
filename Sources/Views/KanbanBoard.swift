import SwiftUI

struct KanbanBoard: View {
    let viewModel: BoardViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: Theme.columnSpacing) {
                ForEach(KanbanColumn.allCases) { column in
                    ColumnView(
                        column: column,
                        prs: viewModel.prs(for: column),
                        tasks: viewModel.tasks(for: column),
                        viewModel: viewModel
                    )
                    .frame(minWidth: 280, idealWidth: 300)
                }
            }
            .padding(Theme.columnSpacing)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - Column

struct ColumnView: View {
    let column: KanbanColumn
    let prs: [PullRequest]
    let tasks: [BoardTask]
    let viewModel: BoardViewModel

    private var itemCount: Int { prs.count + tasks.count }

    var body: some View {
        VStack(spacing: 0) {
            columnHeader
                .padding(.horizontal, Theme.columnPadding)
                .padding(.top, Theme.columnPadding)
                .padding(.bottom, 8)

            if itemCount == 0 {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: Theme.cardSpacing) {
                        // Task cards (Triage, Plan, Build columns)
                        ForEach(tasks, id: \.id) { task in
                            TaskCard(
                                task: task,
                                accentColor: column.accentColor,
                                viewModel: viewModel,
                                onDelete: { viewModel.removeTask(task) }
                            )
                            .transition(.opacity.combined(with: .scale(0.97)))
                        }

                        // PR cards (Draft, Validation, In Review, Approved, Merged columns)
                        ForEach(prs, id: \.id) { pr in
                            PRCard(
                                pr: pr,
                                accentColor: column.accentColor,
                                availableApps: viewModel.availableApps,
                                viewModel: viewModel,
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
        .frame(maxHeight: .infinity, alignment: .top)
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

            // "+" button for Triage column
            if column == .triage {
                Button { viewModel.showNewTaskSheet = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(column.accentColor)
                        .frame(width: 20, height: 20)
                        .background(column.accentColor.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
                .pointingHand()
                .help("Create a new task")
            }

            Text("\(itemCount)")
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
