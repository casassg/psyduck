import Foundation

/// Wraps the `gh` CLI. Stateless (only stores the resolved binary path),
/// so it is safe to share across tasks without serializing through an actor.
final class GitHubService: Sendable {
    private let ghPath: String

    init() {
        let knownPaths = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
        ]
        self.ghPath = knownPaths.first { FileManager.default.fileExists(atPath: $0) } ?? "gh"
    }

    // MARK: - Setup Check

    /// Returns .ok, .ghNotInstalled, or .ghNotAuthenticated.
    func checkSetup() -> BoardViewModel.SetupStatus {
        // Check if gh binary exists
        guard FileManager.default.fileExists(atPath: ghPath) else {
            return .ghNotInstalled
        }

        // Check if gh is authenticated: `gh auth status` exits 0 when logged in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = ["auth", "status"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = Self.defaultEnv

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? .ok : .ghNotAuthenticated
        } catch {
            return .ghNotInstalled
        }
    }

    // MARK: - Public API

    /// Fetch all PRs for the board: open + recently merged, then enrich ALL with `gh pr view`.
    func fetchAllPRs() async throws -> [PullRequest] {
        async let openPRs = fetchOpenPRs()
        async let mergedPRs = fetchMergedPRs()

        var all = try await openPRs
        all.append(contentsOf: try await mergedPRs)

        // Enrich every PR in parallel: gh pr view for details + gh pr checks for required CI status.
        try await withThrowingTaskGroup(of: (Int, PRViewResult?, [RequiredCheck]?).self) { group in
            for (index, pr) in all.enumerated() {
                group.addTask {
                    async let detail = try? self.fetchPRDetail(
                        repo: pr.repoFullName, number: pr.number)
                    async let checks = try? self.fetchRequiredChecks(
                        repo: pr.repoFullName, number: pr.number)
                    return (index, await detail, await checks)
                }
            }
            for try await (index, detail, checks) in group {
                if let detail {
                    all[index].reviewDecision = detail.reviewDecision
                    all[index].mergeStateStatus = detail.mergeStateStatus
                    all[index].additions = detail.additions
                    all[index].deletions = detail.deletions
                    all[index].headRefName = detail.headRefName
                }
                if let checks {
                    all[index].hasFailedRequiredChecks = checks.contains { $0.bucket == "fail" || $0.bucket == "cancel" }
                    all[index].hasRunningRequiredChecks = checks.contains { $0.bucket == "pending" }
                }
            }
        }

        return all
    }

    /// Merge a pull request.
    func mergePR(repo: String, number: Int, strategy: MergeStrategy) async throws {
        try await runGHVoid([
            "pr", "merge", String(number),
            "--repo", repo,
            strategy.ghFlag,
            "--delete-branch",
        ])
    }

    /// Mark a draft PR as ready for review.
    func publishPR(repo: String, number: Int) async throws {
        try await runGHVoid([
            "pr", "ready", String(number),
            "--repo", repo,
        ])
    }

    /// Update a PR branch with latest changes from the base branch.
    func updateBranch(repo: String, number: Int) async throws {
        try await runGHVoid([
            "pr", "update-branch", String(number),
            "--repo", repo,
            "--rebase",
        ])
    }

    /// Close a pull request and delete its branch.
    func closePR(repo: String, number: Int) async throws {
        try await runGHVoid([
            "pr", "close", String(number),
            "--repo", repo,
            "--delete-branch",
        ])
    }

    // MARK: - Open PRs

    private func fetchOpenPRs() async throws -> [PullRequest] {
        let results: [SearchPRResult] = try await runGH([
            "search", "prs",
            "--author", "@me",
            "--state", "open",
            "--limit", "100",
            "--json",
            "id,number,title,repository,isDraft,state,url,createdAt,updatedAt,commentsCount",
        ])
        return results.map { $0.toPullRequest() }
    }

    private func fetchPRDetail(repo: String, number: Int) async throws -> PRViewResult {
        try await runGH([
            "pr", "view", String(number),
            "--repo", repo,
            "--json", "number,reviewDecision,mergeStateStatus,additions,deletions,headRefName",
        ])
    }

    private func fetchRequiredChecks(repo: String, number: Int) async throws -> [RequiredCheck] {
        try await runGH([
            "pr", "checks", String(number),
            "--repo", repo,
            "--required",
            "--json", "bucket",
        ])
    }

    // MARK: - Merged PRs

    private func fetchMergedPRs() async throws -> [PullRequest] {
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let datePrefix = ISO8601DateFormatter().string(from: sevenDaysAgo).prefix(10)

        let results: [SearchPRResult] = try await runGH([
            "search", "prs",
            "--author", "@me",
            "--merged",
            "--merged-at", ">=\(datePrefix)",
            "--limit", "50",
            "--json",
            "id,number,title,repository,isDraft,state,url,createdAt,updatedAt,commentsCount",
        ])

        return results.map { $0.toPullRequest() }
    }

    // MARK: - Process Runners

    /// Run gh and decode JSON output.
    private func runGH<T: Decodable & Sendable>(_ arguments: [String]) async throws -> T {
        let path = self.ghPath
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.environment = Self.defaultEnv

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: GitHubServiceError.processLaunchFailed(error))
                return
            }

            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                continuation.resume(
                    throwing: GitHubServiceError.nonZeroExit(Int(process.terminationStatus)))
                return
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            do {
                let result = try JSONDecoder().decode(T.self, from: data)
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: GitHubServiceError.decodingFailed(error))
            }
        }
    }

    /// Run gh without expecting JSON output (for merge/close commands).
    private func runGHVoid(_ arguments: [String]) async throws {
        let path = self.ghPath
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe
            process.environment = Self.defaultEnv

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: GitHubServiceError.processLaunchFailed(error))
                return
            }

            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
                let msg =
                    stderrStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "gh exited with code \(process.terminationStatus)"
                    : stderrStr.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(throwing: GitHubServiceError.commandFailed(msg))
                return
            }

            continuation.resume()
        }
    }

    private static let defaultEnv: [String: String] = [
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "HOME": NSHomeDirectory(),
        "GH_NO_UPDATE_NOTIFIER": "1",
    ]
}

enum GitHubServiceError: LocalizedError {
    case processLaunchFailed(Error)
    case nonZeroExit(Int)
    case decodingFailed(Error)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .processLaunchFailed(let error):
            "Failed to launch gh CLI: \(error.localizedDescription)"
        case .nonZeroExit(let code):
            "gh CLI exited with code \(code). Is gh installed and authenticated?"
        case .decodingFailed(let error):
            "Failed to parse gh output: \(error.localizedDescription)"
        case .commandFailed(let msg):
            msg
        }
    }
}
