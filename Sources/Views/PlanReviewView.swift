import SwiftUI

/// Sheet for reviewing a plan. Shows markdown with line numbers and allows
/// inserting inline review comments as blockquotes.
struct PlanReviewView: View {
    let task: BoardTask
    let planText: String
    let viewModel: BoardViewModel
    /// (repos, agentId, model, variant)
    let onApprove: ([String], String, String?, String?) -> Void
    let onRevise: (String) -> Void
    let onDismiss: () -> Void

    @State private var editablePlan: String
    @State private var commentLine: Int?
    @State private var commentText = ""
    @State private var showBuildPicker = false

    init(
        task: BoardTask,
        planText: String,
        viewModel: BoardViewModel,
        onApprove: @escaping ([String], String, String?, String?) -> Void,
        onRevise: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.task = task
        self.planText = planText
        self.viewModel = viewModel
        self.onApprove = onApprove
        self.onRevise = onRevise
        self.onDismiss = onDismiss
        self._editablePlan = State(initialValue: planText)
    }

    private var lines: [String] {
        editablePlan.components(separatedBy: "\n")
    }

    private var hasComments: Bool {
        editablePlan.contains("> **REVIEW**:")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan Review")
                        .font(Theme.toolbarTitleFont)
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(task.displayIdentifier): \(task.title)")
                        .font(Theme.metaFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .pointingHand()
            }
            .padding(16)

            Divider().opacity(0.15)

            // Plan content with line numbers
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { lineNum, line in
                        lineRow(lineNum: lineNum + 1, text: line)
                    }
                }
                .padding(.vertical, 8)
            }

            // Comment insertion area
            if let commentLine {
                Divider().opacity(0.15)
                commentInput(forLine: commentLine)
            }

            Divider().opacity(0.15)

            // Action buttons
            HStack(spacing: 12) {
                if hasComments {
                    Text("\(countComments()) comment(s)")
                        .font(Theme.metaFont)
                        .foregroundStyle(Theme.inReviewAccent)
                }

                Spacer()

                Button {
                    onRevise(editablePlan)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                        Text("Revise")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.inReviewAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Theme.inReviewAccent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .pointingHand()
                .disabled(!hasComments)
                .help(hasComments ? "Send back for revision" : "Add comments first")

                Button {
                    showBuildPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("Approve & Build")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Theme.approvedAccent.opacity(0.8), in: Capsule())
                }
                .buttonStyle(.plain)
                .pointingHand()
                .popover(isPresented: $showBuildPicker) {
                    AgentPickerPopover(
                        title: "Start Building",
                        viewModel: viewModel,
                        defaultAgentId: viewModel.agentPreferences.defaultBuildingAgentId,
                        showRepos: true,
                        onStart: { agentId, model, variant, repos in
                            showBuildPicker = false
                            onApprove(repos, agentId, model, variant)
                        }
                    )
                }
            }
            .padding(16)
        }
        .frame(minWidth: 700, maxWidth: 800, minHeight: 500, maxHeight: 700)
        .background(Theme.windowBackground)
    }

    // MARK: - Line Row

    private func lineRow(lineNum: Int, text: String) -> some View {
        let isComment = text.trimmingCharacters(in: .whitespaces).hasPrefix("> **REVIEW**:")

        return HStack(alignment: .top, spacing: 0) {
            // Line number
            Text("\(lineNum)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 36, alignment: .trailing)
                .padding(.trailing, 8)

            // Line content
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(isComment ? Theme.inReviewAccent : Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            // Comment button
            Button {
                commentLine = lineNum
                commentText = ""
            } label: {
                Image(systemName: "bubble.left")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .pointingHand()
            .frame(width: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .background(isComment ? Theme.inReviewAccent.opacity(0.05) : Color.clear)
    }

    // MARK: - Comment Input

    private func commentInput(forLine line: Int) -> some View {
        HStack(spacing: 8) {
            Text("Line \(line):")
                .font(Theme.metaFont)
                .foregroundStyle(Theme.textTertiary)

            TextField("Review comment...", text: $commentText)
                .textFieldStyle(.plain)
                .font(Theme.metaFont)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 6))
                .onSubmit { insertComment() }

            Button("Add") { insertComment() }
                .font(Theme.metaFont)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.validationAccent)
                .pointingHand()
                .disabled(commentText.trimmingCharacters(in: .whitespaces).isEmpty)

            Button("Cancel") {
                commentLine = nil
                commentText = ""
            }
            .font(Theme.metaFont)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textTertiary)
            .pointingHand()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func insertComment() {
        guard let line = commentLine,
              !commentText.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }

        var lineArray = editablePlan.components(separatedBy: "\n")
        let insertIndex = min(line, lineArray.count)
        lineArray.insert("> **REVIEW**: \(commentText.trimmingCharacters(in: .whitespaces))", at: insertIndex)
        editablePlan = lineArray.joined(separator: "\n")
        commentLine = nil
        commentText = ""
    }

    private func countComments() -> Int {
        editablePlan.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("> **REVIEW**:") }
            .count
    }

}
