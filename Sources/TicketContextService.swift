import Foundation

/// Exports a BoardTask to a self-contained markdown file for agent consumption.
/// Also handles shallow-cloning repos for planning context.
struct TicketContextService: Sendable {

    private static let psyduckDir: URL = {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".psyduck", isDirectory: true)
    }()

    /// Export a task to context.md and return the plan directory URL.
    func exportContext(for task: BoardTask) throws -> URL {
        let planDir = Self.psyduckDir
            .appendingPathComponent("plans", isDirectory: true)
            .appendingPathComponent(task.folderIdentifier, isDirectory: true)

        try FileManager.default.createDirectory(at: planDir, withIntermediateDirectories: true)

        let contextPath = planDir.appendingPathComponent("context.md")
        let markdown = buildMarkdown(for: task)
        try markdown.write(to: contextPath, atomically: true, encoding: .utf8)

        return planDir
    }

    /// Shallow-clone repos for planning context. Returns clone paths.
    func cloneRepos(_ repoNames: [String], into planDir: URL) async throws -> [URL] {
        let reposDir = planDir.appendingPathComponent("repos", isDirectory: true)
        try FileManager.default.createDirectory(at: reposDir, withIntermediateDirectories: true)

        var clonePaths: [URL] = []
        for repo in repoNames {
            let safeName = repo.replacingOccurrences(of: "/", with: "--")
            let clonePath = reposDir.appendingPathComponent(safeName)

            // Skip if already cloned
            if FileManager.default.fileExists(atPath: clonePath.path) {
                clonePaths.append(clonePath)
                continue
            }

            try await runProcess(
                "/usr/bin/env",
                arguments: ["gh", "repo", "clone", repo, clonePath.path, "--", "--depth=1"],
                environment: [
                    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                    "HOME": NSHomeDirectory(),
                    "GH_NO_UPDATE_NOTIFIER": "1",
                ]
            )
            clonePaths.append(clonePath)
        }
        return clonePaths
    }

    // MARK: - Markdown Generation

    private func buildMarkdown(for task: BoardTask) -> String {
        var md = ""

        // Header
        md += "# \(task.displayIdentifier): \(task.title)\n\n"

        // Metadata
        var meta: [String] = []
        if let priority = task.priority { meta.append("**Priority**: \(priority.label)") }
        if !task.labels.isEmpty { meta.append("**Labels**: \(task.labels.joined(separator: ", "))") }
        if let url = task.url { meta.append("**URL**: \(url)") }
        if !meta.isEmpty { md += meta.joined(separator: " | ") + "\n\n" }

        // Description
        if let description = task.description, !description.isEmpty {
            md += "## Description\n\n\(description)\n\n"
        }

        // Comments
        if !task.comments.isEmpty {
            md += "## Comments\n\n"
            for comment in task.comments {
                let dateStr = ISO8601DateFormatter().string(from: comment.createdAt)
                md += "### @\(comment.author) (\(dateStr))\n\(comment.body)\n\n"
            }
        }

        // Links
        if !task.links.isEmpty {
            md += "## Links\n\n"
            for link in task.links {
                md += "- \(link)\n"
            }
            md += "\n"
        }

        // User-provided additional context
        if let userContext = task.userContext, !userContext.isEmpty {
            md += "## Additional Context\n\n\(userContext)\n\n"
        }

        return md
    }

    // MARK: - Process Helper

    private func runProcess(
        _ executablePath: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            let stderrPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe
            process.environment = environment

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(throwing: ContextServiceError.cloneFailed(stderr))
            } else {
                continuation.resume()
            }
        }
    }
}

enum ContextServiceError: LocalizedError {
    case cloneFailed(String)

    var errorDescription: String? {
        switch self {
        case .cloneFailed(let msg): "Failed to clone repo: \(msg)"
        }
    }
}
