import Foundation

// MARK: - JSON-RPC 2.0 Base Types

struct JSONRPCRequest: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: JSONValue?
}

struct JSONRPCNotification: Encodable, Sendable {
    let jsonrpc = "2.0"
    let method: String
    let params: JSONValue?
}

struct JSONRPCResponse: Decodable, Sendable {
    let id: Int?
    let result: JSONValue?
    let error: JSONRPCError?

    struct JSONRPCError: Decodable, Sendable {
        let code: Int
        let message: String
    }
}

/// Incoming message from agent — could be a response or a notification.
struct JSONRPCMessage: Decodable, Sendable {
    let id: Int?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: JSONRPCResponse.JSONRPCError?

    var isNotification: Bool { id == nil && method != nil }
    var isResponse: Bool { id != nil }
}

// MARK: - Dynamic JSON Value

/// A type-erased JSON value for dynamic ACP payloads.
enum JSONValue: Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Int.self) { self = .int(v); return }
        if let v = try? container.decode(Double.self) { self = .double(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? container.decode([String: JSONValue].self) { self = .object(v); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

// MARK: - ACP Session Update (parsed from session/update notifications)

enum ACPSessionUpdate: Sendable {
    case agentMessage(text: String)
    case plan(entries: [ACPPlanEntry])
    case toolCall(ACPToolCall)
    case toolCallUpdate(ACPToolCallUpdate)
    case userMessage(text: String)
    case unknown(raw: String)
}

struct ACPPlanEntry: Sendable, Identifiable {
    let id = UUID()
    let content: String
    let priority: String // "high", "medium", "low"
    let status: String   // "pending", "in_progress", "completed"
}

struct ACPToolCall: Sendable, Identifiable {
    let id: String
    let title: String
    let kind: String  // "read", "edit", "execute", "search", "think", "other"
    let status: String
    var content: String?
    var diffPath: String?
    var diffOldText: String?
    var diffNewText: String?
    var terminalId: String?
}

struct ACPToolCallUpdate: Sendable {
    let toolCallId: String
    let status: String?
    var content: String?
}

enum ACPStopReason: String, Sendable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case cancelled
    case refusal
    case unknown

    init(from value: String) {
        self = ACPStopReason(rawValue: value) ?? .unknown
    }
}

// MARK: - ACP Content Block (for prompts)

enum ACPContentBlock: Sendable {
    case text(String)
    case resource(uri: String, mimeType: String?, text: String)

    func toJSON() -> JSONValue {
        switch self {
        case .text(let text):
            return .object(["type": .string("text"), "text": .string(text)])
        case .resource(let uri, let mimeType, let text):
            var resource: [String: JSONValue] = [
                "uri": .string(uri),
                "text": .string(text),
            ]
            if let mimeType { resource["mimeType"] = .string(mimeType) }
            return .object([
                "type": .string("resource"),
                "resource": .object(resource),
            ])
        }
    }
}

// MARK: - Parsing ACP Notifications

extension ACPSessionUpdate {
    /// Parse a session/update notification params into a typed update.
    static func parse(params: JSONValue?) -> ACPSessionUpdate {
        guard let obj = params?.objectValue,
              let updateType = obj["update"]?["sessionUpdate"]?.stringValue ?? obj["update"]?.objectValue?["sessionUpdate"]?.stringValue
        else {
            return .unknown(raw: String(describing: params))
        }

        let update = obj["update"]?.objectValue ?? [:]

        switch updateType {
        case "agent_message_chunk":
            let text = update["content"]?["text"]?.stringValue ?? ""
            return .agentMessage(text: text)

        case "user_message_chunk":
            let text = update["content"]?["text"]?.stringValue ?? ""
            return .userMessage(text: text)

        case "plan":
            let entries = update["entries"]?.arrayValue ?? []
            let parsed = entries.compactMap { entry -> ACPPlanEntry? in
                guard let obj = entry.objectValue,
                      let content = obj["content"]?.stringValue,
                      let priority = obj["priority"]?.stringValue,
                      let status = obj["status"]?.stringValue
                else { return nil }
                return ACPPlanEntry(content: content, priority: priority, status: status)
            }
            return .plan(entries: parsed)

        case "tool_call":
            let tc = ACPToolCall(
                id: update["toolCallId"]?.stringValue ?? UUID().uuidString,
                title: update["title"]?.stringValue ?? "Tool call",
                kind: update["kind"]?.stringValue ?? "other",
                status: update["status"]?.stringValue ?? "pending"
            )
            return .toolCall(tc)

        case "tool_call_update":
            let tcu = ACPToolCallUpdate(
                toolCallId: update["toolCallId"]?.stringValue ?? "",
                status: update["status"]?.stringValue,
                content: update["content"]?.arrayValue?.first?["content"]?.objectValue?["text"]?.stringValue
            )
            return .toolCallUpdate(tcu)

        default:
            return .unknown(raw: updateType)
        }
    }
}
