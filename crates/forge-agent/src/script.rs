//! A model that answers from a script.
//!
//! Public rather than `#[cfg(test)]` because the runner's own integration tests
//! need it too — driving a whole task through the HTTP API, the approval queue
//! and the review endpoint is only worth doing if the model's half is
//! deterministic. It follows [`forge_gateway::StubClient`], which is public for
//! the same reason.
//!
//! It does not simulate prompt caching; [`forge_gateway::StubClient`] already
//! does that, and the numbers that matter are asserted there.

use std::sync::{Arc, Mutex};

use forge_core::types::Usage;
use forge_gateway::ToolCall;
use forge_gateway::dispatch::{DispatchError, ModelClient, ModelRequest, ModelResponse, Refusal};

/// One scripted reply.
#[derive(Debug, Clone, PartialEq)]
pub struct ScriptedTurn {
    pub text: String,
    pub calls: Vec<ToolCall>,
    pub refusal: Option<Refusal>,
}

#[derive(Clone)]
pub struct ScriptedClient {
    turns: Arc<Mutex<std::collections::VecDeque<ScriptedTurn>>>,
    /// Replayed once the script runs out. `None` means "stop with a plain text
    /// reply", which ends a loop rather than hanging it.
    repeat: Option<ScriptedTurn>,
    requests: Arc<Mutex<Vec<ModelRequest>>>,
}

impl ScriptedClient {
    pub fn new(turns: Vec<ScriptedTurn>) -> Self {
        Self {
            turns: Arc::new(Mutex::new(turns.into())),
            repeat: None,
            requests: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// A model that answers the same way forever — for exercising step limits.
    pub fn looping(turn: ScriptedTurn) -> Self {
        Self {
            turns: Arc::new(Mutex::new(Default::default())),
            repeat: Some(turn),
            requests: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// A turn that just talks, which is how the loop learns the task is done.
    pub fn text(text: impl Into<String>) -> ScriptedTurn {
        ScriptedTurn {
            text: text.into(),
            calls: Vec::new(),
            refusal: None,
        }
    }

    /// A turn that asks for tools. Ids are positional, matching the provider's
    /// habit of one id per block.
    pub fn calls(calls: Vec<(&str, serde_json::Value)>) -> ScriptedTurn {
        ScriptedTurn {
            text: String::new(),
            calls: calls
                .into_iter()
                .enumerate()
                .map(|(index, (name, input))| ToolCall {
                    id: format!("toolu_{index}"),
                    name: name.to_owned(),
                    input,
                })
                .collect(),
            refusal: None,
        }
    }

    pub fn refusal(explanation: &str) -> ScriptedTurn {
        ScriptedTurn {
            text: String::new(),
            calls: Vec::new(),
            refusal: Some(Refusal {
                category: Some("cyber".into()),
                explanation: Some(explanation.to_owned()),
            }),
        }
    }

    /// Everything the loop actually sent. Assertions about prompt shape and
    /// call count live on this.
    pub fn requests(&self) -> Vec<ModelRequest> {
        self.requests.lock().expect("requests poisoned").clone()
    }

    pub fn call_count(&self) -> usize {
        self.requests.lock().expect("requests poisoned").len()
    }
}

impl ModelClient for ScriptedClient {
    async fn complete(&self, request: ModelRequest) -> Result<ModelResponse, DispatchError> {
        let model = request.model.clone();
        self.requests
            .lock()
            .expect("requests poisoned")
            .push(request);

        let turn = self
            .turns
            .lock()
            .expect("script poisoned")
            .pop_front()
            .or_else(|| self.repeat.clone())
            .unwrap_or_else(|| Self::text("(the script ran out)"));

        let refused = turn.refusal.is_some();
        Ok(ModelResponse {
            text: turn.text,
            // Small but non-zero, so a scripted run moves the ledger and the
            // budget guard the way a real one would.
            usage: Usage {
                input_tokens: 500,
                output_tokens: 120,
                cache_write_tokens: 0,
                cache_read_tokens: 2_000,
            },
            model,
            stop_reason: Some(
                if refused {
                    "refusal"
                } else if turn.calls.is_empty() {
                    "end_turn"
                } else {
                    "tool_use"
                }
                .into(),
            ),
            refusal: turn.refusal,
            tool_calls: if refused { Vec::new() } else { turn.calls },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use forge_core::price::price_of;
    use forge_gateway::prompt::{StableContext, assemble};

    fn request() -> ModelRequest {
        ModelRequest {
            model: "claude-sonnet-5".into(),
            max_tokens: 64,
            effort: None,
            plan: assemble(
                &StableContext::default(),
                "hi",
                &price_of("claude-sonnet-5").unwrap(),
            ),
        }
    }

    #[tokio::test]
    async fn the_script_is_replayed_in_order() {
        let client = ScriptedClient::new(vec![
            ScriptedClient::calls(vec![("read_file", serde_json::json!({"path": "a"}))]),
            ScriptedClient::text("done"),
        ]);

        let first = client.complete(request()).await.unwrap();
        assert_eq!(first.stop_reason.as_deref(), Some("tool_use"));
        assert_eq!(first.tool_calls[0].name, "read_file");

        let second = client.complete(request()).await.unwrap();
        assert_eq!(second.text, "done");
        assert!(second.tool_calls.is_empty());
        assert_eq!(client.call_count(), 2);
    }

    #[tokio::test]
    async fn an_exhausted_script_stops_rather_than_looping_forever() {
        let client = ScriptedClient::new(Vec::new());
        let response = client.complete(request()).await.unwrap();
        assert!(response.tool_calls.is_empty());
        assert_eq!(response.stop_reason.as_deref(), Some("end_turn"));
    }

    #[tokio::test]
    async fn a_looping_client_never_runs_out() {
        let client = ScriptedClient::looping(ScriptedClient::calls(vec![(
            "list_files",
            serde_json::json!({}),
        )]));
        for _ in 0..5 {
            assert!(
                !client
                    .complete(request())
                    .await
                    .unwrap()
                    .tool_calls
                    .is_empty()
            );
        }
    }

    #[tokio::test]
    async fn a_refusal_carries_no_tool_calls() {
        let client = ScriptedClient::new(vec![ScriptedClient::refusal("no")]);
        let response = client.complete(request()).await.unwrap();
        assert!(response.refusal.is_some());
        assert!(response.tool_calls.is_empty());
    }
}
