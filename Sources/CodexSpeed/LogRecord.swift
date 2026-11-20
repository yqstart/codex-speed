import Foundation

struct TokenCounts: Decodable {
    let output: Int
    let total: Int?

    private enum CodingKeys: String, CodingKey {
        case output = "output_tokens"
        case total = "total_tokens"
    }
}

struct LogRecord {
    enum Event {
        case metadata(id: String?, desktop: Bool, subagent: Bool)
        case turnStarted, userInput, turnEnded, modelOutput
        case model(String)
        case toolCall(String)
        case toolResult(String)
        case modernUsage(id: String?, tokens: Int?)
        case legacyUsage(total: TokenCounts, last: TokenCounts?)
    }

    let event: Event
    let time: Date
}

final class LogRecordDecoder {
    private struct Envelope: Decodable {
        struct Payload: Decodable {
            struct Source: Decodable {
                private enum CodingKeys: String, CodingKey { case subagent }
                let isSubagent: Bool

                init(from decoder: Decoder) throws {
                    let object = try? decoder.container(keyedBy: CodingKeys.self)
                    let label = try? decoder.singleValueContainer().decode(String.self)
                    isSubagent = object?.contains(.subagent) == true || label == "subagent"
                }
            }

            struct UsageInfo: Decodable {
                let total: TokenCounts?
                let last: TokenCounts?

                private enum CodingKeys: String, CodingKey {
                    case total = "total_token_usage"
                    case last = "last_token_usage"
                }
            }

            struct ThreadSettings: Decodable {
                let model: String?
            }

            let type: String?
            let id: String?
            let role: String?
            let model: String?
            let threadSettings: ThreadSettings?
            let source: Source?
            let originator: String?
            let threadSource: String?
            let callID: String?
            let responseID: String?
            let usage: TokenCounts?
            let info: UsageInfo?

            private enum CodingKeys: String, CodingKey {
                case type, id, role, model, source, originator, usage, info
                case threadSettings = "thread_settings"
                case threadSource = "thread_source"
                case callID = "call_id"
                case responseID = "response_id"
            }
        }

        let timestamp: String
        let type: String
        let payload: Payload

        var event: LogRecord.Event? {
            switch (type, payload.type) {
            case ("session_meta", _):
                let desktop = payload.originator?.lowercased() == "codex desktop"
                let subagent = payload.threadSource == "subagent" || payload.source?.isSubagent == true
                return .metadata(id: payload.id, desktop: desktop, subagent: subagent)
            case ("turn_context", _):
                return payload.model.flatMap(modelEvent)
            case ("event_msg", "thread_settings_applied"):
                return payload.threadSettings?.model.flatMap(modelEvent)
            case ("event_msg", "task_started"):
                return .turnStarted
            case ("event_msg", "user_message"):
                return .userInput
            case ("response_item", "message") where payload.role == "user":
                return .userInput
            case ("event_msg", "task_complete"), ("event_msg", "turn_aborted"):
                return .turnEnded
            case ("response_item", "reasoning"):
                return .modelOutput
            case ("response_item", "message") where payload.role == "assistant":
                return .modelOutput
            case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
                return payload.callID.map(LogRecord.Event.toolCall) ?? .modelOutput
            case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"):
                return payload.callID.map(LogRecord.Event.toolResult)
            case ("token_usage_record", _):
                return .modernUsage(id: payload.responseID, tokens: payload.usage?.output)
            case ("event_msg", "token_count"):
                guard let info = payload.info, let total = info.total else { return nil }
                return .legacyUsage(total: total, last: info.last)
            default:
                return nil
            }
        }

        private func modelEvent(_ value: String) -> LogRecord.Event? {
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : .model(name)
        }
    }

    private let json = JSONDecoder()
    private let date = ISO8601DateFormatter()
    private let fractionalDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func decode(_ line: Data) -> LogRecord? {
        // 读取会话标识、模型、时间、事件类型和用量字段。
        guard let envelope = try? json.decode(Envelope.self, from: line), let event = envelope.event,
              let time = fractionalDate.date(from: envelope.timestamp) ?? date.date(from: envelope.timestamp) else { return nil }
        return LogRecord(event: event, time: time)
    }
}
