import Foundation

// MARK: - WSClient 领域处理（AI）

extension WSClient {
    func handleAiDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "ai_task_cancelled":
            if let result = AITaskCancelled.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAITaskCancelled(result)
                } else {
                    onAITaskCancelled?(result)
                }
            }
            return true
        case "ai_session_started":
            if let ev = AISessionStartedV2.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAISessionStarted(ev)
                } else {
                    onAISessionStarted?(ev)
                }
            }
            return true
        case "ai_session_list":
            if let ev = AISessionListV2.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAISessionList(ev)
                } else {
                    onAISessionList?(ev)
                }
            }
            return true
        case "ai_session_messages":
            if let ev = AISessionMessagesV2.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAISessionMessages(ev)
                } else {
                    onAISessionMessages?(ev)
                }
            }
            return true
        case "ai_session_status_result":
            if let ev = AISessionStatusResultV2.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAISessionStatusResult(ev)
                } else {
                    onAISessionStatusResult?(ev)
                }
            }
            return true
        case "ai_session_status_update":
            if let ev = AISessionStatusUpdateV2.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAISessionStatusUpdate(ev)
                } else {
                    onAISessionStatusUpdate?(ev)
                }
            }
            return true
        case "ai_chat_message_updated":
            if let ev = AIChatMessageUpdatedV2.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAIChatMessageUpdated(ev)
                } else {
                    onAIChatMessageUpdated?(ev)
                }
            }
            return true
        case "ai_chat_part_updated":
            if let ev = AIChatPartUpdatedV2.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAIChatPartUpdated(ev)
                } else {
                    onAIChatPartUpdated?(ev)
                }
            }
            return true
        case "ai_chat_part_delta":
            if let ev = AIChatPartDeltaV2.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAIChatPartDelta(ev)
                } else {
                    onAIChatPartDelta?(ev)
                }
            }
            return true
        case "ai_chat_done":
            if let ev = AIChatDoneV2.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAIChatDone(ev)
                } else {
                    onAIChatDone?(ev)
                }
            }
            return true
        case "ai_chat_error":
            if let ev = AIChatErrorV2.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAIChatError(ev)
                } else {
                    onAIChatError?(ev)
                }
            }
            return true
        case "ai_question_asked":
            if let ev = AIQuestionAskedV2.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAIQuestionAsked(ev)
                } else {
                    onAIQuestionAsked?(ev)
                }
            }
            return true
        case "ai_question_cleared":
            if let ev = AIQuestionClearedV2.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAIQuestionCleared(ev)
                } else {
                    onAIQuestionCleared?(ev)
                }
            }
            return true
        case "ai_provider_list":
            if let ev = AIProviderListResult.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAIProviderList(ev)
                } else {
                    onAIProviderList?(ev)
                }
            }
            return true
        case "ai_agent_list":
            if let ev = AIAgentListResult.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAIAgentList(ev)
                } else {
                    onAIAgentList?(ev)
                }
            }
            return true
        case "ai_slash_commands":
            if let ev = AISlashCommandsResult.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAISlashCommands(ev)
                } else {
                    onAISlashCommands?(ev)
                }
            }
            return true
        case "ai_slash_commands_update":
            if let ev = AISlashCommandsUpdateResult.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAISlashCommandsUpdate(ev)
                } else {
                    onAISlashCommandsUpdate?(ev)
                }
            }
            return true
        case "ai_session_config_options":
            if let ev = AISessionConfigOptionsResult.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAISessionConfigOptions(ev)
                } else {
                    onAISessionConfigOptions?(ev)
                }
            }
            return true
        case "ai_session_subscribe_ack":
            if let handler = aiMessageHandler {
                handler.handleAISessionSubscribeAck()
            }
            return true
        default:
            return false
        }
    }
}
