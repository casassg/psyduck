import Foundation

/// Fetches tickets from Linear's GraphQL API using a personal API key.
/// Read-only: no writes to Linear.
struct LinearService: Sendable {

    private static let endpoint = URL(string: "https://api.linear.app/graphql")!

    /// Fetch tickets created by or assigned to the authenticated user.
    /// Returns transient DTOs — caller is responsible for upserting into BoardTask.
    func fetchMyTickets(apiKey: String) async throws -> [LinearTicketDTO] {
        let query = """
            query {
              viewer {
                assignedIssues(
                  filter: { state: { type: { nin: ["completed", "canceled"] } } }
                  orderBy: updatedAt
                  first: 100
                ) {
                  nodes {
                    id
                    identifier
                    title
                    description
                    priority
                    state { name }
                    assignee { name }
                    creator { name }
                    labels { nodes { name } }
                    url
                    branchName
                    comments { nodes { body createdAt user { name } } }
                    createdAt
                    updatedAt
                  }
                }
                createdIssues(
                  filter: { state: { type: { nin: ["completed", "canceled"] } } }
                  orderBy: updatedAt
                  first: 100
                ) {
                  nodes {
                    id
                    identifier
                    title
                    description
                    priority
                    state { name }
                    assignee { name }
                    creator { name }
                    labels { nodes { name } }
                    url
                    branchName
                    comments { nodes { body createdAt user { name } } }
                    createdAt
                    updatedAt
                  }
                }
              }
            }
            """

        let body: [String: Any] = ["query": query]
        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LinearServiceError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw LinearServiceError.httpError(httpResponse.statusCode)
        }

        let result = try JSONDecoder().decode(LinearGraphQLResponse.self, from: data)

        // Merge assigned + created, deduplicate by id
        var seen = Set<String>()
        var tickets: [LinearTicketDTO] = []
        for ticket in result.data.viewer.assignedIssues.nodes + result.data.viewer.createdIssues.nodes {
            if seen.insert(ticket.id).inserted {
                tickets.append(ticket)
            }
        }

        return tickets
    }

    /// Upsert Linear tickets into existing tasks. Returns the updated task list.
    func sync(tickets: [LinearTicketDTO], into existing: [BoardTask]) -> [BoardTask] {
        var tasks = existing
        let linearIdsInResponse = Set(tickets.map(\.id))

        // Remove tasks that would be in triage (no plan, no worktrees, no PRs)
        // whose Linear ticket disappeared from the API response.
        tasks.removeAll { task in
            task.linearId != nil
                && !linearIdsInResponse.contains(task.linearId!)
                && task.planStatus == nil
                && task.worktrees == nil
                && (task.draftPRRefs == nil || task.draftPRRefs!.isEmpty)
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for dto in tickets {
            if let idx = tasks.firstIndex(where: { $0.linearId == dto.id }) {
                let dtoUpdated = isoFormatter.date(from: dto.updatedAt) ?? Date()
                if dtoUpdated > (tasks[idx].lastSyncedAt ?? .distantPast) {
                    tasks[idx].title = dto.title
                    tasks[idx].description = dto.description
                    tasks[idx].priority = TaskPriority(rawValue: dto.priority ?? 0)
                    tasks[idx].labels = dto.labels.nodes.map(\.name)
                    tasks[idx].branchName = dto.branchName
                    tasks[idx].url = dto.url
                    tasks[idx].comments = dto.comments.nodes.map { c in
                        TaskComment(
                            author: c.user?.name ?? "Unknown",
                            body: c.body,
                            createdAt: isoFormatter.date(from: c.createdAt) ?? Date()
                        )
                    }
                    tasks[idx].lastSyncedAt = dtoUpdated
                    tasks[idx].updatedAt = dtoUpdated
                }
            } else {
                tasks.append(dto.toBoardTask())
            }
        }

        return tasks
    }
}

// MARK: - GraphQL Response Shape

private struct LinearGraphQLResponse: Decodable, Sendable {
    let data: ViewerData

    struct ViewerData: Decodable, Sendable {
        let viewer: Viewer
    }
    struct Viewer: Decodable, Sendable {
        let assignedIssues: IssueConnection
        let createdIssues: IssueConnection
    }
    struct IssueConnection: Decodable, Sendable {
        let nodes: [LinearTicketDTO]
    }
}

// MARK: - Errors

enum LinearServiceError: LocalizedError {
    case invalidResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid response from Linear API."
        case .httpError(let code): "Linear API returned HTTP \(code)."
        }
    }
}
