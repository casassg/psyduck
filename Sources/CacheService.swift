import Foundation

/// Persists PR data to ~/Library/Caches/com.gerardc.gh-prs/ so the app can
/// show stale-but-instant results on launch while refreshing in the background.
struct CacheService: Sendable {

    private static let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("com.gerardc.psyduck", isDirectory: true)
    }()

    private static let prsFile = cacheDir.appendingPathComponent("pullRequests.json")
    private static let tasksFile = cacheDir.appendingPathComponent("tasks.json")
    private static let metaFile = cacheDir.appendingPathComponent("meta.json")

    // MARK: - Load (synchronous — called once at init)

    struct CachedData: Sendable {
        let pullRequests: [PullRequest]
        let tasks: [BoardTask]
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

        // Tasks cache is optional — older caches won't have it
        let tasks: [BoardTask] = {
            guard let data = try? Data(contentsOf: Self.tasksFile) else { return [] }
            return (try? decoder.decode([BoardTask].self, from: data)) ?? []
        }()

        return CachedData(pullRequests: prs, tasks: tasks, lastRefresh: meta.lastRefresh)
    }

    // MARK: - Save (called after each successful refresh)

    func save(pullRequests: [PullRequest], tasks: [BoardTask], lastRefresh: Date) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            try FileManager.default.createDirectory(
                at: Self.cacheDir, withIntermediateDirectories: true)
            let prsData = try encoder.encode(pullRequests)
            try prsData.write(to: Self.prsFile, options: .atomic)
            let tasksData = try encoder.encode(tasks)
            try tasksData.write(to: Self.tasksFile, options: .atomic)
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
