//! Persisted, text-only project conversations and inference attempts.

use serde::{Deserialize, Serialize};

use crate::types::WorkMode;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProjectChat {
    pub id: String,
    pub project_id: String,
    pub repo_id: String,
    pub title: String,
    pub created_at: i64,
    pub updated_at: i64,
    /// The session its replies are charged to and narrated on: a client
    /// follows that session's output to show what a reply is reading.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub session_id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChatRole {
    User,
    Assistant,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatMessage {
    pub id: String,
    pub conversation_id: String,
    pub role: ChatRole,
    pub content: String,
    pub created_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// The mode the message was asked or answered in.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<WorkMode>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChatTurnStatus {
    Pending,
    Completed,
    Failed,
    Interrupted,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatTurn {
    pub request_id: String,
    pub status: ChatTurnStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<WorkMode>,
    /// The model the turn asked for, as named; `None` is the mode's default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatDetail {
    pub conversation: ProjectChat,
    pub messages: Vec<ChatMessage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub latest_turn: Option<ChatTurn>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatReply {
    pub detail: ChatDetail,
    /// The requested attempt, which may predate `detail.latest_turn` on replay.
    pub turn: ChatTurn,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProjectChatPage {
    pub conversations: Vec<ProjectChat>,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateProjectChatRequest {
    pub repo_id: String,
    pub title: String,
    pub budget_usd: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SendChatMessageRequest {
    pub content: String,
    pub request_id: String,
    /// `ask` when absent. A conversation answers in Ask or Plan; Agent and
    /// Review are task modes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<WorkMode>,
    /// A registry model or alias; the mode's default when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
}
