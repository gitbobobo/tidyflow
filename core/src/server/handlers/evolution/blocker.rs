use crate::ai::AiQuestionRequest;
use crate::server::context::HandlerContext;
use crate::server::protocol::{EvolutionBlockerResolutionInput, ServerMessage};

use super::EvolutionManager;

impl EvolutionManager {
    pub(super) async fn emit_blocking_required_if_any(
        &self,
        _project: &str,
        _workspace: &str,
        _workspace_root: &str,
        _trigger: &str,
        _cycle_id: Option<&str>,
        _stage: Option<&str>,
        _ctx: &HandlerContext,
    ) -> Result<bool, String> {
        // 已移除 workspace.blockers.jsonc 能力：不再生成阻塞文件，也不阻塞进化流程。
        Ok(false)
    }

    pub(super) async fn resolve_blockers(
        &self,
        project: &str,
        workspace: &str,
        _resolutions: Vec<EvolutionBlockerResolutionInput>,
        ctx: &HandlerContext,
    ) -> Result<(), String> {
        // 保留协议入口，统一返回“无未解决 blocker”，用于前端状态收敛。
        self.broadcast(
            ctx,
            ServerMessage::EvoBlockersUpdated {
                project: project.to_string(),
                workspace: workspace.to_string(),
                unresolved_count: 0,
                unresolved_items: Vec::new(),
            },
        )
        .await;
        Ok(())
    }

    pub(super) async fn add_blocker_from_question(
        &self,
        _project: &str,
        _workspace: &str,
        _workspace_root: &str,
        _cycle_id: &str,
        _stage: &str,
        _request: &AiQuestionRequest,
    ) -> Result<(), String> {
        // 已移除 workspace.blockers.jsonc 能力：忽略 AI 问题触发的人类 blocker 落盘。
        Ok(())
    }

    pub(super) async fn has_stage_blocker(
        &self,
        _workspace_root: &str,
        _project: &str,
        _workspace: &str,
        _cycle_id: &str,
        _stage: &str,
    ) -> bool {
        false
    }
}
