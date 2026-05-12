import Foundation

/// ACP (Agent Client Protocol) client. Communicates with any ACP-compatible coding agent
/// via JSON-RPC 2.0 over stdio. Spawns agent as a subprocess.
final class ACPClient: @unchecked Sendable {
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private var requestId = 0
    private var pendingRequests: [Int: CheckedContinuation<JSONValue?, Error>] = [:]
    private let lock = NSLock()
    private var buffer = Data()

    var onUpdate: (@Sendable (ACPSessionUpdate) -> Void)?
    var onPermissionRequest: (@Sendable (String, JSONValue?) async -> JSONValue)?

    private init(process: Process, stdinPipe: Pipe, stdoutPipe: Pipe) {
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
    }

    // MARK: - Connect + Initialize

    /// Spawn an ACP agent and complete the initialize handshake.
    static func connect(
        command: String,
        args: [String] = [],
        env: [String: String] = [:]
    ) async throws -> ACPClient {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        // Resolve command from PATH
        let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(NSHomeDirectory())/.local/bin"
        var environment: [String: String] = [
            "PATH": searchPath,
            "HOME": NSHomeDirectory(),
        ]
        for (key, value) in env {
            environment[key] = value
        }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = environment

        let client = ACPClient(process: process, stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
        client.startReading()

        try process.run()

        // Send initialize
        let initParams: JSONValue = .object([
            "protocolVersion": .int(1),
            "clientCapabilities": .object([
                "fs": .object([
                    "readTextFile": .bool(true),
                    "writeTextFile": .bool(true),
                ]),
                "terminal": .bool(true),
            ]),
            "clientInfo": .object([
                "name": .string("psyduck"),
                "title": .string("PsyDuck"),
                "version": .string("2.0.0"),
            ]),
        ])

        let _ = try await client.sendRequest(method: "initialize", params: initParams)
        return client
    }

    // MARK: - Session Management

    func createSession(cwd: URL) async throws -> String {
        let params: JSONValue = .object([
            "cwd": .string(cwd.path),
        ])
        let result = try await sendRequest(method: "session/new", params: params)
        guard let sessionId = result?["sessionId"]?.stringValue else {
            throw ACPError.invalidResponse("session/new did not return sessionId")
        }
        return sessionId
    }

    func closeSession(id: String) async throws {
        let params: JSONValue = .object(["sessionId": .string(id)])
        let _ = try await sendRequest(method: "session/close", params: params)
    }

    /// Resume a previously saved session (requires agent loadSession capability).
    func loadSession(id: String) async throws {
        let params: JSONValue = .object(["sessionId": .string(id)])
        let _ = try await sendRequest(method: "session/load", params: params)
    }

    // MARK: - Prompts

    /// Send a prompt and wait for the turn to complete. Returns the stop reason.
    func prompt(sessionId: String, content: [ACPContentBlock]) async throws -> ACPStopReason {
        let contentArray: JSONValue = .array(content.map { $0.toJSON() })
        let params: JSONValue = .object([
            "sessionId": .string(sessionId),
            "prompt": contentArray,
        ])
        let result = try await sendRequest(method: "session/prompt", params: params)
        let reason = result?["stopReason"]?.stringValue ?? "end_turn"
        return ACPStopReason(from: reason)
    }

    // MARK: - Control

    func cancel(sessionId: String) {
        let notification = JSONRPCNotification(
            method: "session/cancel",
            params: .object(["sessionId": .string(sessionId)])
        )
        sendNotification(notification)
    }

    func kill() {
        if process.isRunning {
            process.terminate()
        }
    }

    var isRunning: Bool { process.isRunning }

    // MARK: - JSON-RPC Transport

    private func sendRequest(method: String, params: JSONValue?) async throws -> JSONValue? {
        let id = nextId()
        let request = JSONRPCRequest(id: id, method: method, params: params)

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingRequests[id] = continuation
            lock.unlock()

            do {
                let data = try JSONEncoder().encode(request)
                let frame = "Content-Length: \(data.count)\r\n\r\n".data(using: .utf8)! + data
                stdinPipe.fileHandleForWriting.write(frame)
            } catch {
                lock.lock()
                pendingRequests.removeValue(forKey: id)
                lock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(_ notification: JSONRPCNotification) {
        guard let data = try? JSONEncoder().encode(notification) else { return }
        let frame = "Content-Length: \(data.count)\r\n\r\n".data(using: .utf8)! + data
        stdinPipe.fileHandleForWriting.write(frame)
    }

    private func nextId() -> Int {
        lock.lock()
        requestId += 1
        let id = requestId
        lock.unlock()
        return id
    }

    // MARK: - Reading (background)

    private func startReading() {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.lock.lock()
            self.buffer.append(data)
            self.lock.unlock()
            self.processBuffer()
        }
    }

    private func processBuffer() {
        while true {
            lock.lock()
            // Look for Content-Length header
            guard let headerRange = buffer.range(of: "\r\n\r\n".data(using: .utf8)!) else {
                lock.unlock()
                return
            }
            let headerData = buffer[buffer.startIndex..<headerRange.lowerBound]
            guard let headerStr = String(data: headerData, encoding: .utf8),
                  let lengthStr = headerStr.split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
                  let contentLength = Int(lengthStr)
            else {
                lock.unlock()
                return
            }

            let contentStart = headerRange.upperBound
            let contentEnd = buffer.index(contentStart, offsetBy: contentLength)
            guard contentEnd <= buffer.endIndex else {
                lock.unlock()
                return // Not enough data yet
            }

            let messageData = Data(buffer[contentStart..<contentEnd])
            buffer.removeSubrange(buffer.startIndex..<contentEnd)
            lock.unlock()

            handleMessage(messageData)
        }
    }

    private func handleMessage(_ data: Data) {
        guard let message = try? JSONDecoder().decode(JSONRPCMessage.self, from: data) else {
            return
        }

        if let id = message.id, let method = message.method {
            // Request FROM the agent (permission, fs, terminal)
            handleAgentRequest(id: id, method: method, params: message.params)
        } else if message.isResponse, let id = message.id {
            lock.lock()
            let continuation = pendingRequests.removeValue(forKey: id)
            lock.unlock()

            if let error = message.error {
                continuation?.resume(throwing: ACPError.rpcError(error.code, error.message))
            } else {
                continuation?.resume(returning: message.result)
            }
        } else if message.isNotification {
            handleNotification(method: message.method!, params: message.params)
        }
    }

    private func handleNotification(method: String, params: JSONValue?) {
        switch method {
        case "session/update":
            let update = ACPSessionUpdate.parse(params: params)
            onUpdate?(update)

        case "session/request_permission":
            // Permission requests arrive as JSON-RPC requests (with id), not notifications.
            // They are handled in handleAgentRequest. If we get one here as a notification,
            // it's a protocol quirk — just ignore it.
            break

        default:
            break
        }
    }

    // Handle requests FROM the agent (permission, fs, terminal)
    private func handleAgentRequest(id: Int, method: String, params: JSONValue?) {
        switch method {
        case "session/request_permission":
            // Auto-approve: select the first "allow" option
            let options = params?["options"]?.arrayValue ?? []
            let allowOption = options.first { opt in
                opt["kind"]?.stringValue?.hasPrefix("allow") ?? false
            }
            let optionId = allowOption?["optionId"]?.stringValue ?? "allow-once"
            let response: JSONValue = .object([
                "outcome": .object([
                    "outcome": .string("selected"),
                    "optionId": .string(optionId),
                ]),
            ])
            sendResponse(id: id, result: response)

        case "fs/read_text_file":
            // Read file from disk
            let path = params?["path"]?.stringValue ?? ""
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                sendResponse(id: id, result: .object(["text": .string(content)]))
            } else {
                sendErrorResponse(id: id, code: -1, message: "Cannot read file: \(path)")
            }

        case "fs/write_text_file":
            let path = params?["path"]?.stringValue ?? ""
            let text = params?["text"]?.stringValue ?? ""
            do {
                try text.write(toFile: path, atomically: true, encoding: .utf8)
                sendResponse(id: id, result: .object([:]))
            } catch {
                sendErrorResponse(id: id, code: -1, message: "Cannot write file: \(error.localizedDescription)")
            }

        case "terminal/create":
            // Create a terminal subprocess
            let command = params?["command"]?.stringValue ?? ""
            let args = params?["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let cwd = params?["cwd"]?.stringValue

            let termId = "term_\(UUID().uuidString.prefix(8))"
            let termProcess = Process()
            let termPipe = Pipe()

            termProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            termProcess.arguments = [command] + args
            termProcess.standardOutput = termPipe
            termProcess.standardError = termPipe
            if let cwd {
                termProcess.currentDirectoryURL = URL(fileURLWithPath: cwd)
            }
            termProcess.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                "HOME": NSHomeDirectory(),
            ]

            lock.lock()
            terminals[termId] = TerminalState(process: termProcess, output: termPipe)
            lock.unlock()

            do {
                try termProcess.run()
                sendResponse(id: id, result: .object(["terminalId": .string(termId)]))
            } catch {
                sendErrorResponse(id: id, code: -1, message: "Failed to create terminal: \(error.localizedDescription)")
            }

        case "terminal/output":
            let termId = params?["terminalId"]?.stringValue ?? ""
            lock.lock()
            let state = terminals[termId]
            lock.unlock()
            let data = state?.output.fileHandleForReading.availableData ?? Data()
            let text = String(data: data, encoding: .utf8) ?? ""
            var result: [String: JSONValue] = [
                "output": .string(text),
                "truncated": .bool(false),
            ]
            if let proc = state?.process, !proc.isRunning {
                result["exitStatus"] = .object([
                    "exitCode": .int(Int(proc.terminationStatus)),
                    "signal": .null,
                ])
            }
            sendResponse(id: id, result: .object(result))

        case "terminal/wait_for_exit":
            let termId = params?["terminalId"]?.stringValue ?? ""
            lock.lock()
            let state = terminals[termId]
            lock.unlock()
            Task {
                state?.process.waitUntilExit()
                let code = state?.process.terminationStatus ?? -1
                self.sendResponse(id: id, result: .object([
                    "exitCode": .int(Int(code)),
                    "signal": .null,
                ]))
            }

        case "terminal/release", "terminal/kill":
            let termId = params?["terminalId"]?.stringValue ?? ""
            lock.lock()
            let state = terminals.removeValue(forKey: termId)
            lock.unlock()
            if let proc = state?.process, proc.isRunning {
                proc.terminate()
            }
            sendResponse(id: id, result: .object([:]))

        default:
            sendErrorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // Terminal state tracking
    private struct TerminalState {
        let process: Process
        let output: Pipe
    }
    private var terminals: [String: TerminalState] = [:]

    private func sendResponse(id: Int, result: JSONValue) {
        let response: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "result": result,
        ]
        guard let data = try? JSONEncoder().encode(response) else { return }
        let frame = "Content-Length: \(data.count)\r\n\r\n".data(using: .utf8)! + data
        stdinPipe.fileHandleForWriting.write(frame)
    }

    private func sendErrorResponse(id: Int, code: Int, message: String) {
        let response: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "error": .object([
                "code": .int(code),
                "message": .string(message),
            ]),
        ]
        guard let data = try? JSONEncoder().encode(response) else { return }
        let frame = "Content-Length: \(data.count)\r\n\r\n".data(using: .utf8)! + data
        stdinPipe.fileHandleForWriting.write(frame)
    }
}

// MARK: - Errors

enum ACPError: LocalizedError {
    case invalidResponse(String)
    case rpcError(Int, String)
    case agentNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let msg): "Invalid ACP response: \(msg)"
        case .rpcError(let code, let msg): "ACP error \(code): \(msg)"
        case .agentNotFound(let cmd): "Agent '\(cmd)' not found on PATH"
        }
    }
}
