import Foundation

/// Persists PR data to ~/Library/Caches/com.gerardc.gh-prs/ so the app can
/// show stale-but-instant results on launch while refreshing in the background.
struct CacheService: Sendable {

    private static let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("com.gerardc.gh-prs", isDirectory: true)
    }()

    private static let prsFile = cacheDir.appendingPathComponent("pullRequests.json")
    private static let metaFile = cacheDir.appendingPathComponent("meta.json")

    // MARK: - Load (synchronous — called once at init)

    struct CachedData: Sendable {
        let pullRequests: [PullRequest]
        let lastRefresh: Date
    }

    func load() -> CachedData? {
        guard
            let prsData = try? Data(contentsOf: Self.prsFile),
            let metaData = try? Data(contentsOf: Self.metaFile)
        else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard
            let prs = try? decoder.decode([PullRequest].self, from: prsData),
            let meta = try? decoder.decode(CacheMeta.self, from: metaData)
        else { return nil }

        return CachedData(pullRequests: prs, lastRefresh: meta.lastRefresh)
    }

    // MARK: - Save (called after each successful refresh)

    func save(pullRequests: [PullRequest], lastRefresh: Date) {
        // Strip worktree data — it's re-scanned fresh each launch
        let stripped = pullRequests.map { pr -> PullRequest in
            var copy = pr
            copy.worktree = nil
            return copy
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            try FileManager.default.createDirectory(
                at: Self.cacheDir, withIntermediateDirectories: true)
            let prsData = try encoder.encode(stripped)
            try prsData.write(to: Self.prsFile, options: .atomic)
            let metaData = try encoder.encode(CacheMeta(lastRefresh: lastRefresh))
            try metaData.write(to: Self.metaFile, options: .atomic)
        } catch {
            // Cache write failure is non-fatal — silently ignore
        }
    }
}

private struct CacheMeta: Codable {
    let lastRefresh: Date
}
