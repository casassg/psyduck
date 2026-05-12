import Foundation

/// Creates and manages worktrees under ~/.psyduck/worktrees/{identifier}/{repo-name}/.
/// Always fetches origin and branches from the latest default branch.
struct TaskWorktreeService: Sendable {

    private static let worktreeRoot: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".psyduck", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
    }()

    private static let defaultEnv: [String: String] = [
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "HOME": NSHomeDirectory(),
        "GH_NO_UPDATE_NOTIFIER": "1",
    ]

    /// Create worktrees for a task. One per selected repo.
    /// - Parameters:
    ///   - task: The board task (provides folderIdentifier and branchName).
    ///   - repos: Tuples of (fullName, localPath) for each repo to create a worktree in.
    /// - Returns: Array of TaskWorktree with paths to the created worktrees.
    func createWorktrees(
        for task: BoardTask,
        repos: [(fullName: String, localPath: URL)]
    ) async throws -> [TaskWorktree] {
        let identifier = task.folderIdentifier
        let branchName = task.branchName ?? "\(task.folderIdentifier)-work"
        let taskDir = Self.worktreeRoot.appendingPathComponent(identifier, isDirectory: true)

        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)

        var worktrees: [TaskWorktree] = []

        for (fullName, localPath) in repos {
            let repoName = fullName.split(separator: "/").last.map(String.init) ?? fullName
            let worktreePath = taskDir.appendingPathComponent(repoName)

            // 1. Fetch latest from origin
            try await git(["fetch", "origin"], in: localPath)

            // 2. Detect default branch
            let defaultBranch = try await detectDefaultBranch(fullName: fullName)

            // 3. Check if branch already exists on remote
            let remoteBranchExists = try await branchExistsOnRemote(
                branchName: branchName, in: localPath)

            // 4. Create worktree
            if remoteBranchExists {
                // Check out existing remote branch
                try await git(
                    ["worktree", "add", worktreePath.path, "origin/\(branchName)"],
                    in: localPath
                )
            } else {
                // Create new branch from latest origin/defaultBranch
                try await git(
                    ["worktree", "add", worktreePath.path,
                     "-b", branchName, "origin/\(defaultBranch)"],
                    in: localPath
                )
            }

            worktrees.append(TaskWorktree(
                repoFullName: fullName,
                branch: branchName,
                path: worktreePath.path
            ))
        }

        return worktrees
    }

    /// Remove worktrees for a task identifier.
    func removeWorktrees(identifier: String, repos: [(fullName: String, localPath: URL)]) async throws {
        for (_, localPath) in repos {
            let taskDir = Self.worktreeRoot.appendingPathComponent(identifier)
            // Remove all worktrees registered from this repo that live under taskDir
            let list = try await gitOutput(["worktree", "list", "--porcelain"], in: localPath)
            for line in list.components(separatedBy: "\n") where line.hasPrefix("worktree ") {
                let path = String(line.dropFirst("worktree ".count))
                if path.hasPrefix(taskDir.path) {
                    try await git(["worktree", "remove", path, "--force"], in: localPath)
                }
            }
        }

        // Clean up the directory
        let taskDir = Self.worktreeRoot.appendingPathComponent(identifier)
        try? FileManager.default.removeItem(at: taskDir)
    }

    // MARK: - Helpers

    private func detectDefaultBranch(fullName: String) async throws -> String {
        let output = try await processOutput(
            "/usr/bin/env",
            arguments: ["gh", "api", "repos/\(fullName)", "--jq", ".default_branch"],
            environment: Self.defaultEnv
        )
        let branch = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? "main" : branch
    }

    private func branchExistsOnRemote(branchName: String, in repoPath: URL) async throws -> Bool {
        let output = try await gitOutput(
            ["ls-remote", "--heads", "origin", branchName], in: repoPath)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func git(_ arguments: [String], in directory: URL) async throws {
        try await runProcess("/usr/bin/git", arguments: arguments, cwd: directory)
    }

    private func gitOutput(_ arguments: [String], in directory: URL) async throws -> String {
        try await processOutput("/usr/bin/git", arguments: arguments, cwd: directory)
    }

    private func runProcess(
        _ executablePath: String,
        arguments: [String],
        cwd: URL? = nil,
        environment: [String: String] = Self.defaultEnv
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            let stderrPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe
            process.environment = environment
            if let cwd { process.currentDirectoryURL = cwd }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(throwing: TaskWorktreeError.operationFailed(stderr))
            } else {
                continuation.resume()
            }
        }
    }

    private func processOutput(
        _ executablePath: String,
        arguments: [String],
        cwd: URL? = nil,
        environment: [String: String] = Self.defaultEnv
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice
            process.environment = environment
            if let cwd { process.currentDirectoryURL = cwd }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            process.waitUntilExit()
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                continuation.resume(throwing: TaskWorktreeError.operationFailed(output))
            } else {
                continuation.resume(returning: output)
            }
        }
    }
}

enum TaskWorktreeError: LocalizedError {
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .operationFailed(let msg): "Worktree operation failed: \(msg)"
        }
    }
}
