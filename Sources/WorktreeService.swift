import Foundation

/// Scans tracked folders for git repos and discovers worktrees.
/// Maps (owner/repo, branch) → Worktree for PR association.
final class WorktreeService: Sendable {

    /// Key for the worktree lookup map: identifies a specific branch in a specific repo.
    struct WorktreeKey: Hashable, Sendable {
        let repoFullName: String  // e.g. "squareup/gondola-sdk"
        let branch: String  // e.g. "gerardc/fix-tests"
    }

    /// Scan all tracked folders and build a worktree lookup map.
    /// For each tracked folder, discovers git repos as direct children,
    /// then runs `git worktree list --porcelain` and `git remote get-url origin`
    /// to associate worktrees with GitHub repos.
    func scanWorktrees(trackedFolders: [String]) async -> [WorktreeKey: Worktree] {
        var result: [WorktreeKey: Worktree] = [:]

        // Find all git repos in tracked folders (direct children only)
        let repoPaths = findGitRepos(in: trackedFolders)

        // Process repos in parallel
        await withTaskGroup(of: [(WorktreeKey, Worktree)].self) { group in
            for repoPath in repoPaths {
                group.addTask {
                    await self.discoverWorktrees(mainRepoPath: repoPath)
                }
            }
            for await entries in group {
                for (key, worktree) in entries {
                    result[key] = worktree
                }
            }
        }

        return result
    }

    /// Remove a git worktree directory.
    func removeWorktree(mainRepoPath: String, worktreePath: String, force: Bool = false)
        async throws
    {
        var args = ["-C", mainRepoPath, "worktree", "remove", worktreePath]
        if force { args.append("--force") }
        let (_, stderr, exitCode) = await runShell("/usr/bin/git", arguments: args)
        if exitCode != 0 {
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorktreeError.removeFailed(
                msg.isEmpty ? "git worktree remove failed (exit \(exitCode))" : msg)
        }
    }

    // MARK: - Private

    /// Find git repos that are direct children of the tracked folders.
    private func findGitRepos(in folders: [String]) -> [String] {
        let fm = FileManager.default
        var repos: [String] = []

        for folder in folders {
            guard
                let children = try? fm.contentsOfDirectory(
                    atPath: folder)
            else { continue }

            for child in children {
                let childPath = (folder as NSString).appendingPathComponent(child)
                let gitPath = (childPath as NSString).appendingPathComponent(".git")
                // Check for regular repos (.git directory) or bare repos (.git file for worktree links)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: gitPath, isDirectory: &isDir) {
                    repos.append(childPath)
                }
            }
        }

        return repos
    }

    /// For a single git repo, discover all worktrees and their associated GitHub remote.
    private func discoverWorktrees(mainRepoPath: String) async -> [(WorktreeKey, Worktree)] {
        // Get the GitHub owner/repo from the origin remote
        guard let repoFullName = await extractGitHubRepo(from: mainRepoPath) else {
            return []
        }

        // Get all worktrees via porcelain format
        let (output, _, exitCode) = await runShell(
            "/usr/bin/git",
            arguments: ["-C", mainRepoPath, "worktree", "list", "--porcelain"])
        guard exitCode == 0 else { return [] }

        // Parse porcelain output:
        //   worktree /path/to/worktree
        //   HEAD <sha>
        //   branch refs/heads/<branch>
        //   (blank line)
        var entries: [(WorktreeKey, Worktree)] = []
        var currentPath: String?
        var currentBranch: String?

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if line.hasPrefix("worktree ") {
                currentPath = String(line.dropFirst("worktree ".count))
                currentBranch = nil
            } else if line.hasPrefix("branch refs/heads/") {
                currentBranch = String(line.dropFirst("branch refs/heads/".count))
            } else if line.isEmpty || line.hasPrefix("HEAD ") || line == "bare"
                || line == "detached"
            {
                // Either separator or metadata we don't need
                if line.isEmpty, let path = currentPath, let branch = currentBranch {
                    let key = WorktreeKey(repoFullName: repoFullName, branch: branch)
                    let wt = Worktree(
                        path: path, mainRepoPath: mainRepoPath, branch: branch)
                    entries.append((key, wt))
                    currentPath = nil
                    currentBranch = nil
                }
            }
        }
        // Handle last entry if file doesn't end with a blank line
        if let path = currentPath, let branch = currentBranch {
            let key = WorktreeKey(repoFullName: repoFullName, branch: branch)
            let wt = Worktree(path: path, mainRepoPath: mainRepoPath, branch: branch)
            entries.append((key, wt))
        }

        return entries
    }

    /// Extract "owner/repo" from a git repo's origin remote URL.
    /// Handles both SSH (`git@github.com:owner/repo.git`) and HTTPS (`https://github.com/owner/repo.git`).
    private func extractGitHubRepo(from repoPath: String) async -> String? {
        let (output, _, exitCode) = await runShell(
            "/usr/bin/git",
            arguments: ["-C", repoPath, "remote", "get-url", "origin"])
        guard exitCode == 0 else { return nil }

        let url = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // SSH format: git@github.com:owner/repo.git
        if let range = url.range(of: "github.com:") {
            let afterHost = url[range.upperBound...]
            return String(afterHost).replacingOccurrences(of: ".git", with: "")
        }

        // HTTPS format: https://github.com/owner/repo.git
        if let range = url.range(of: "github.com/") {
            let afterHost = url[range.upperBound...]
            return String(afterHost).replacingOccurrences(of: ".git", with: "")
        }

        return nil
    }

    /// Run a shell command and return (stdout, stderr, exitCode).
    private func runShell(_ executable: String, arguments: [String]) async -> (
        String, String, Int32
    ) {
        await withCheckedContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                "HOME": NSHomeDirectory(),
            ]

            do {
                try process.run()
            } catch {
                continuation.resume(returning: ("", error.localizedDescription, 1))
                return
            }

            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            continuation.resume(
                returning: (stdout, stderr, process.terminationStatus))
        }
    }
}

enum WorktreeError: LocalizedError {
    case removeFailed(String)

    var errorDescription: String? {
        switch self {
        case .removeFailed(let msg): msg
        }
    }
}
