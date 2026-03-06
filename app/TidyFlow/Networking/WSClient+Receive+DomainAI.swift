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
        case "ai_session_messages_update":
            if let ev = AISessionMessagesUpdateV2.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAISessionMessagesUpdate(ev)
                } else {
                    onAISessionMessagesUpdate?(ev)
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
        case "ai_chat_done":
            if let ev = AIChatDoneV2.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAIChatDone(ev)
                } else {
                    onAIChatDone?(ev)
                }
            }
            return true
        case "ai_chat_pending":
            if let ev = AIChatPendingV2.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAIChatPending(ev)
                } else {
                    onAIChatPending?(ev)
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
        case "ai_session_rename_result":
            if let ev = AISessionRenameResult.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAISessionRenameResult(ev)
                } else {
                    onAISessionRenameResult?(ev)
                }
            }
            return true
        case "ai_session_search_result":
            if let ev = AISessionSearchResult.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAISessionSearchResult(ev)
                } else {
                    onAISessionSearchResult?(ev)
                }
            }
            return true
        case "ai_code_review_result":
            if let ev = AICodeReviewResult.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAICodeReviewResult(ev)
                } else {
                    onAICodeReviewResult?(ev)
                }
            }
            return true
        case "ai_code_completion_chunk":
            if let ev = AICodeCompletionChunk.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAICodeCompletionChunk(ev)
                } else {
                    onAICodeCompletionChunk?(ev)
                }
            }
            return true
        case "ai_code_completion_done":
            if let ev = AICodeCompletionDone.from(json: json) {
                if let handler = aiMessageHandler {
                    handler.handleAICodeCompletionDone(ev)
                } else {
                    onAICodeCompletionDone?(ev)
                }
            }
            return true
        default:
            return false
        }
    }
}
