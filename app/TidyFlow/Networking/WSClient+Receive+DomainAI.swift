import Foundation

// MARK: - WSClient 领域处理（AI）

extension WSClient {
    func handleAiDomain(_ action: String, json: [String: Any]) -> Bool {
        switch action {
        case "ai_task_cancelled":
            if let result = AITaskCancelled.from(json: json) {
                onAITaskCancelled?(result)
            }
            return true
        case "ai_session_started":
            if let ev = AISessionStartedV2.from(json: json) {
                onAISessionStarted?(ev)
            }
            return true
        case "ai_session_list":
            if let ev = AISessionListV2.from(json: json) {
                onAISessionList?(ev)
            }
            return true
        case "ai_session_messages":
            if let ev = AISessionMessagesV2.from(json: json) {
                onAISessionMessages?(ev)
            }
            return true
        case "ai_session_status_result":
            if let ev = AISessionStatusResultV2.from(json: json) {
                onAISessionStatusResult?(ev)
            }
            return true
        case "ai_session_status_update":
            if let ev = AISessionStatusUpdateV2.from(json: json) {
                onAISessionStatusUpdate?(ev)
            }
            return true
        case "ai_chat_message_updated":
            if let ev = AIChatMessageUpdatedV2.from(json: json) {
                onAIChatMessageUpdated?(ev)
            }
            return true
        case "ai_chat_part_updated":
            if let ev = AIChatPartUpdatedV2.from(json: json) {
                onAIChatPartUpdated?(ev)
            }
            return true
        case "ai_chat_part_delta":
            if let ev = AIChatPartDeltaV2.from(json: json) {
                onAIChatPartDelta?(ev)
            }
            return true
        case "ai_chat_done":
            if let ev = AIChatDoneV2.from(json: json) {
                onAIChatDone?(ev)
            }
            return true
        case "ai_chat_error":
            if let ev = AIChatErrorV2.from(json: json) {
                onAIChatError?(ev)
            }
            return true
        case "ai_question_asked":
            if let ev = AIQuestionAskedV2.from(json: json) {
                onAIQuestionAsked?(ev)
            }
            return true
        case "ai_question_cleared":
            if let ev = AIQuestionClearedV2.from(json: json) {
                onAIQuestionCleared?(ev)
            }
            return true
        case "ai_provider_list":
            if let ev = AIProviderListResult.from(json: json) {
                onAIProviderList?(ev)
            }
            return true
        case "ai_agent_list":
            if let ev = AIAgentListResult.from(json: json) {
                onAIAgentList?(ev)
            }
            return true
        case "ai_slash_commands":
            if let ev = AISlashCommandsResult.from(json: json) {
                onAISlashCommands?(ev)
            }
            return true
        default:
            return false
        }
    }
}
