import Foundation

/// Manages plan files on disk under ~/.psyduck/plans/.
struct PlanService: Sendable {

    private static let psyduckDir: URL = {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".psyduck", isDirectory: true)
    }()

    /// Path to the plan.md for a given task.
    func planPath(for task: BoardTask) -> URL {
        Self.psyduckDir
            .appendingPathComponent("plans", isDirectory: true)
            .appendingPathComponent(task.folderIdentifier, isDirectory: true)
            .appendingPathComponent("plan.md")
    }

    /// Read a plan file. Returns nil if it doesn't exist.
    func readPlan(for task: BoardTask) -> String? {
        let path = planPath(for: task)
        return try? String(contentsOf: path, encoding: .utf8)
    }

    /// Check if a plan has inline review comments (> **REVIEW**: blocks).
    func hasReviewComments(in planText: String) -> Bool {
        planText.contains("> **REVIEW**:")
    }

    /// Extract review comments from a plan.
    func extractReviewComments(from planText: String) -> [String] {
        planText.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("> **REVIEW**:") }
            .map { line in
                line.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "> **REVIEW**: ", with: "")
                    .replacingOccurrences(of: "> **REVIEW**:", with: "")
            }
    }

    /// Insert a review comment into a plan at a specific line.
    func insertComment(in planText: String, atLine lineNumber: Int, comment: String) -> String {
        var lines = planText.components(separatedBy: "\n")
        let commentBlock = "\n> **REVIEW**: \(comment)\n"
        let insertIndex = min(lineNumber, lines.count)
        lines.insert(commentBlock, at: insertIndex)
        return lines.joined(separator: "\n")
    }

    /// Copy the plan file from one task's directory to another's.
    func copyPlan(from source: BoardTask, to destination: BoardTask) throws {
        let srcPath = planPath(for: source)
        let dstPath = planPath(for: destination)
        let fm = FileManager.default
        try fm.createDirectory(at: dstPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dstPath.path) {
            try fm.removeItem(at: dstPath)
        }
        try fm.copyItem(at: srcPath, to: dstPath)
    }

    /// Build the planning prompt for a task.
    func buildPlanningPrompt(task: BoardTask, contextPath: URL, repoClonePaths: [URL]) -> String {
        var prompt = """
            You are a senior software engineer. Write a detailed plan for the following task.

            Read the task context at: \(contextPath.appendingPathComponent("context.md").path)

            """

        if !repoClonePaths.isEmpty {
            prompt += "\nRelevant codebase(s) cloned at:\n"
            for path in repoClonePaths {
                prompt += "- \(path.path)\n"
            }
        }

        prompt += """

            Browse the code, then write a plan covering:
            1. Problem statement.
            2. Proposed approach.
            3. Files/modules to change.
            4. New files to create.
            5. Testing strategy.
            6. Rollout considerations.
            7. Open questions.

            Write the plan to: \(planPath(for: task).path)
            Be specific about code paths and file references.
            """

        return prompt
    }

    /// Build a revision prompt with review comments.
    func buildRevisionPrompt(task: BoardTask) -> String {
        """
        Revise the plan at: \(planPath(for: task).path)

        Address all `> **REVIEW**:` comments inline. After addressing each comment,
        remove the comment block. Keep the rest of the plan structure intact.
        Improve any sections based on the feedback.
        """
    }
}
