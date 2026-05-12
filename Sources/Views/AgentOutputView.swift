import SwiftUI

/// Displays real-time ACP agent events: messages, tool calls, plan steps.
struct AgentOutputView: View {
    let events: [AgentOutputEvent]
    let isRunning: Bool
    var onSteer: ((String) -> Void)?
    var onCancel: (() -> Void)?

    @State private var steeringText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Event log
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                            eventRow(event)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: events.count) { _, _ in
                    if let last = events.indices.last {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isRunning {
                Divider().opacity(0.1)

                // Steering input + cancel
                HStack(spacing: 6) {
                    TextField("Send message...", text: $steeringText)
                        .textFieldStyle(.plain)
                        .font(Theme.metaFont)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 6))
                        .onSubmit {
                            sendSteering()
                        }

                    Button {
                        sendSteering()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.validationAccent)
                    }
                    .buttonStyle(.plain)
                    .pointingHand()
                    .disabled(steeringText.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button {
                        onCancel?()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.diffDeletion)
                    }
                    .buttonStyle(.plain)
                    .pointingHand()
                    .help("Stop agent")
                }
                .padding(8)
            }
        }
        .background(Theme.surfaceBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.cardBorder, lineWidth: 0.5)
        )
    }

    private func sendSteering() {
        let text = steeringText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        onSteer?(text)
        steeringText = ""
    }

    @ViewBuilder
    private func eventRow(_ event: AgentOutputEvent) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: event.icon)
                .font(.system(size: 9))
                .foregroundStyle(event.iconColor)
                .frame(width: 14)

            Text(event.text)
                .font(Theme.metaFont)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Agent Output Event (view model for the output view)

struct AgentOutputEvent: Sendable, Equatable {
    let text: String
    let kind: Kind

    enum Kind: Sendable, Equatable {
        case message
        case thinking
        case readFile
        case writeFile
        case execute
        case search
        case plan
        case error
        case completed
    }

    var icon: String {
        switch kind {
        case .message: "bubble.left"
        case .thinking: "brain"
        case .readFile: "doc.text"
        case .writeFile: "pencil"
        case .execute: "terminal"
        case .search: "magnifyingglass"
        case .plan: "list.bullet"
        case .error: "exclamationmark.triangle"
        case .completed: "checkmark.circle"
        }
    }

    var iconColor: Color {
        switch kind {
        case .message: Theme.textSecondary
        case .thinking: Theme.planAccent
        case .readFile: Theme.validationAccent
        case .writeFile: Theme.inReviewAccent
        case .execute: Theme.buildAccent
        case .search: Theme.triageAccent
        case .plan: Theme.planAccent
        case .error: Theme.diffDeletion
        case .completed: Theme.approvedAccent
        }
    }

    /// Convert an ACP session update to output events.
    static func from(update: ACPSessionUpdate) -> [AgentOutputEvent] {
        switch update {
        case .agentMessage(let text):
            guard !text.isEmpty else { return [] }
            return [AgentOutputEvent(text: text, kind: .message)]
        case .plan(let entries):
            return entries.map { entry in
                let status = entry.status == "completed" ? "done" : entry.status
                return AgentOutputEvent(text: "[\(status)] \(entry.content)", kind: .plan)
            }
        case .toolCall(let tc):
            let kind: Kind = {
                switch tc.kind {
                case "read": return .readFile
                case "edit": return .writeFile
                case "execute": return .execute
                case "search": return .search
                case "think": return .thinking
                default: return .message
                }
            }()
            return [AgentOutputEvent(text: tc.title, kind: kind)]
        case .toolCallUpdate(let tcu):
            if let content = tcu.content, !content.isEmpty {
                return [AgentOutputEvent(text: content, kind: .message)]
            }
            if tcu.status == "completed" {
                return [AgentOutputEvent(text: "Tool completed", kind: .completed)]
            }
            return []
        case .userMessage:
            return []
        case .unknown(let raw):
            return [AgentOutputEvent(text: "Unknown: \(raw)", kind: .message)]
        }
    }
}
