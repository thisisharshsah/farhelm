use super::*;

use std::net::SocketAddr;
use std::sync::Mutex;

use axum::extract::State;
use axum::routing::post;
use axum::{Json, Router};
use serde_json::Value;

const ALIAS: &str = "fixture-code";
const ACTUAL_MODEL: &str = "fixture-code-revision-2";
const LEDGER_MODEL: &str = "local/fixture/fixture-code-revision-2";

#[derive(Clone, Copy)]
enum Behavior {
    Valid,
    WrongArguments,
    UnknownTool,
    Delayed,
}

struct Provider {
    behavior: Behavior,
    requests: Mutex<Vec<Value>>,
}

async fn respond(State(provider): State<Arc<Provider>>, Json(request): Json<Value>) -> Json<Value> {
    let index = {
        let mut requests = provider.requests.lock().unwrap();
        requests.push(request.clone());
        requests.len()
    };
    if matches!(provider.behavior, Behavior::Delayed) {
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    let tool_result = request["messages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|message| message["role"] == "tool");
    let (message, finish_reason) = if let Some(result) = tool_result {
        let content: Value = serde_json::from_str(result["content"].as_str().unwrap()).unwrap();
        let reply = if content["is_error"] == true {
            ERROR_REPLY
        } else {
            content["content"].as_str().unwrap()
        };
        (json!({ "role": "assistant", "content": reply }), "stop")
    } else if request.get("tools").is_some() {
        let name = if matches!(provider.behavior, Behavior::UnknownTool) {
            "undeclared_fixture"
        } else {
            "lookup_fixture"
        };
        let key = if matches!(provider.behavior, Behavior::WrongArguments) {
            "beta"
        } else {
            "alpha"
        };
        (
            json!({
                "role": "assistant", "content": null,
                "tool_calls": [{
                    "id": format!("fixture-call-{index}"), "type": "function",
                    "function": {
                        "name": name,
                        "arguments": json!({ "key": key }).to_string()
                    }
                }]
            }),
            "tool_calls",
        )
    } else {
        (json!({ "role": "assistant", "content": EXACT }), "stop")
    };
    Json(json!({
        "model": ACTUAL_MODEL,
        "choices": [{ "message": message, "finish_reason": finish_reason }],
        "usage": {
            "prompt_tokens": 100, "completion_tokens": 20,
            "prompt_tokens_details": { "cached_tokens": 10 }
        }
    }))
}

struct Fixture {
    addr: SocketAddr,
    provider: Arc<Provider>,
    server: tokio::task::JoinHandle<()>,
}

impl Fixture {
    async fn start(behavior: Behavior) -> Self {
        let provider = Arc::new(Provider {
            behavior,
            requests: Mutex::new(Vec::new()),
        });
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let addr = listener.local_addr().unwrap();
        let router = Router::new()
            .route("/v1/chat/completions", post(respond))
            .with_state(Arc::clone(&provider));
        let server = tokio::spawn(async move {
            axum::serve(listener, router).await.unwrap();
        });
        Self {
            addr,
            provider,
            server,
        }
    }

    fn config(&self, cloud: bool) -> String {
        let (policy, location, scheme) = if cloud {
            ("cloud_allowed", "cloud", "https")
        } else {
            ("local_only", "local", "http")
        };
        let pricing = if cloud {
            "[models.fixture-code.pricing]\ninput_per_mtok = 2.0\noutput_per_mtok = 4.0\n"
        } else {
            ""
        };
        format!(
            r#"version = 1
policy = "{policy}"
[routes]
small = "{ALIAS}"
large = "{ALIAS}"
frontier = "{ALIAS}"
[providers.fixture]
kind = "openai_compatible"
base_url = "{scheme}://{}/v1"
data_location = "{location}"
[models.fixture-code]
provider = "fixture"
model = "fixture-code-base"
tools = true
max_output_tokens = 128
{pricing}"#,
            self.addr
        )
    }

    fn gateway(&self) -> (ProbeGateway, Arc<SqliteStore>) {
        gateway(
            ProviderClient::from_toml(&self.config(false)).unwrap(),
            ALIAS,
        )
        .unwrap()
    }

    fn requests(&self) -> Vec<Value> {
        self.provider.requests.lock().unwrap().clone()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.server.abort();
    }
}

struct TempFiles(PathBuf);

impl TempFiles {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "farhelm-model-conformance-{}",
            farhelm_app::id::new_id()
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }

    fn options(&self, config: &str) -> Options {
        let path = self.0.join("models.toml");
        std::fs::write(&path, config).unwrap();
        Options {
            config: path,
            model: ALIAS.into(),
            deployment_id: "fixture-base-adapter-runtime-v1".into(),
            report: self.0.join("report.json"),
            allow_cloud: false,
            timeout: Duration::from_secs(2),
        }
    }
}

impl Drop for TempFiles {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn assert_no_content_leak(serialized: &str) {
    for content in [EXACT, VALUE, ERROR_REPLY, "fixture_unavailable", SYSTEM] {
        assert!(
            !serialized.contains(content),
            "evaluation report exposed synthetic prompt or reply content"
        );
    }
    assert!(!serialized.contains("http://"));
    assert!(!serialized.contains("https://"));
}

#[tokio::test]
async fn evaluates_the_five_calls_with_real_gateway_accounting_and_structured_replay() {
    let fixture = Fixture::start(Behavior::Valid).await;
    let (gateway, store) = fixture.gateway();
    let cases = evaluate(&gateway, Duration::from_secs(2)).await;
    assert_eq!(cases.len(), 3);
    assert!(cases.iter().all(|case| case.passed));
    assert_eq!(cases.iter().map(|case| case.calls.len()).sum::<usize>(), 5);
    assert_no_content_leak(&serde_json::to_string(&cases).unwrap());

    let requests = fixture.requests();
    assert_eq!(requests.len(), 5);
    for request in &requests {
        assert_eq!(request["model"], "fixture-code-base");
        assert_eq!(request["max_tokens"], 128);
        assert_eq!(request["stream"], false);
    }
    for (index, is_error) in [(2, false), (4, true)] {
        let messages = requests[index]["messages"].as_array().unwrap();
        let assistant = messages
            .iter()
            .find(|message| message.get("tool_calls").is_some())
            .unwrap();
        let result = messages
            .iter()
            .find(|message| message["role"] == "tool")
            .unwrap();
        assert_eq!(result["tool_call_id"], assistant["tool_calls"][0]["id"]);
        assert_eq!(
            assistant["tool_calls"][0]["function"]["name"],
            "lookup_fixture"
        );
        let arguments: Value = serde_json::from_str(
            assistant["tool_calls"][0]["function"]["arguments"]
                .as_str()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(arguments, json!({ "key": "alpha" }));
        let content: Value = serde_json::from_str(result["content"].as_str().unwrap()).unwrap();
        assert_eq!(content["is_error"], is_error);
        assert_eq!(
            content["content"],
            if is_error {
                "fixture_unavailable"
            } else {
                VALUE
            }
        );
    }
    for (session, count) in [("exact_text", 1), ("tool_success", 2), ("tool_error", 2)] {
        let events = store.list_usage(session, TimeRange::ALL).unwrap();
        assert_eq!(events.len(), count);
        for event in events {
            assert_eq!(event.model, LEDGER_MODEL);
            assert_eq!(event.usage.input_tokens, 90);
            assert_eq!(event.usage.output_tokens, 20);
            assert_eq!(event.usage.cache_read_tokens, 10);
            assert_eq!(event.usage.cache_write_tokens, 0);
            assert_eq!(event.cost_usd, 0.0);
            assert!(event.avoided.is_none());
        }
    }
    for call in cases.iter().flat_map(|case| &case.calls) {
        assert_eq!(call.model.as_deref(), Some(LEDGER_MODEL));
        assert_eq!(call.cost_usd, Some(0.0));
        assert!(call.error.is_none());
    }
    assert_eq!(store.usage_totals(TimeRange::ALL).unwrap().cost_usd, 0.0);
}

#[tokio::test]
async fn rejects_wrong_arguments_and_unknown_tools_without_fabricating_results() {
    for behavior in [Behavior::WrongArguments, Behavior::UnknownTool] {
        let fixture = Fixture::start(behavior).await;
        let (gateway, _) = fixture.gateway();
        let cases = evaluate(&gateway, Duration::from_secs(2)).await;
        assert!(cases[0].passed);
        for case in &cases[1..] {
            assert!(!case.passed);
            assert_eq!(case.calls.len(), 1, "a rejected call was replayed");
            match behavior {
                Behavior::WrongArguments => assert_eq!(case.reason, "unexpected_tool_or_arguments"),
                Behavior::UnknownTool => assert_eq!(case.calls[0].error, Some("provider_error")),
                _ => unreachable!(),
            }
        }
        let requests = fixture.requests();
        assert_eq!(requests.len(), 3);
        assert!(requests.iter().all(|request| {
            request["messages"]
                .as_array()
                .unwrap()
                .iter()
                .all(|message| message["role"] != "tool")
        }));
    }
}

#[tokio::test]
async fn deadlines_fail_cases_without_success_or_usage_rows() {
    let fixture = Fixture::start(Behavior::Delayed).await;
    let (gateway, store) = fixture.gateway();
    let cases = tokio::time::timeout(
        Duration::from_secs(2),
        evaluate(&gateway, Duration::from_millis(10)),
    )
    .await
    .unwrap();
    assert_eq!(cases.len(), 3);
    for case in cases {
        assert!(!case.passed);
        assert_eq!(case.calls.len(), 1);
        assert_eq!(case.calls[0].error, Some("deadline_exceeded"));
        assert!(case.calls[0].usage.is_none());
        assert!(case.calls[0].cost_usd.is_none());
    }
    for session in ["exact_text", "tool_success", "tool_error"] {
        assert!(
            store
                .list_usage(session, TimeRange::ALL)
                .unwrap()
                .is_empty()
        );
    }
}

fn required_args() -> Vec<String> {
    [
        "--config",
        "models.toml",
        "--model",
        ALIAS,
        "--deployment-id",
        "fixture-v1",
        "--report",
        "new-report.json",
        "--run",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect()
}

#[test]
fn command_line_requires_opt_in_and_rejects_ambiguous_or_invalid_options() {
    assert!(options(["--help".into()]).unwrap().is_none());
    assert!(options(["-h".into()]).unwrap().is_none());
    let accepted = options(required_args()).unwrap().unwrap();
    assert!(!accepted.allow_cloud);
    assert_eq!(accepted.timeout, Duration::from_secs(90));
    let mut missing_run = required_args();
    missing_run.pop();
    assert!(options(missing_run).err().unwrap().contains("--run"));
    for extra in [
        vec!["--run"],
        vec!["--model", "another"],
        vec!["--unknown"],
        vec!["--timeout-seconds", "0"],
        vec!["--timeout-seconds", "301"],
        vec!["--timeout-seconds", "NaN"],
        vec!["--timeout-seconds"],
    ] {
        let mut args = required_args();
        args.extend(extra.into_iter().map(str::to_owned));
        assert!(options(args).is_err());
    }
    let mut cloud = required_args();
    cloud.extend([
        "--allow-cloud".into(),
        "--timeout-seconds".into(),
        "7".into(),
    ]);
    let accepted = options(cloud).unwrap().unwrap();
    assert!(accepted.allow_cloud);
    assert_eq!(accepted.timeout, Duration::from_secs(7));
}

#[tokio::test]
async fn cloud_execution_requires_separate_opt_in_before_http_or_report_creation() {
    let fixture = Fixture::start(Behavior::Valid).await;
    let files = TempFiles::new();
    let options = files.options(&fixture.config(true));
    let report_path = options.report.clone();
    let error = run(options).await.unwrap_err();
    assert!(
        error.contains("--allow-cloud"),
        "unexpected rejection: {error}"
    );
    assert!(fixture.requests().is_empty());
    assert!(!report_path.exists());
}

#[tokio::test]
async fn an_existing_report_is_preserved_without_inference() {
    let fixture = Fixture::start(Behavior::Valid).await;
    let files = TempFiles::new();
    let options = files.options(&fixture.config(false));
    let report_path = options.report.clone();
    std::fs::write(&report_path, b"existing-private-report\n").unwrap();
    assert!(run(options).await.is_err());
    assert_eq!(
        std::fs::read(&report_path).unwrap(),
        b"existing-private-report\n"
    );
    assert!(fixture.requests().is_empty());
}

#[tokio::test]
async fn run_writes_a_private_parseable_summary_without_prompt_or_reply_content() {
    let fixture = Fixture::start(Behavior::Valid).await;
    let files = TempFiles::new();
    let options = files.options(&fixture.config(false));
    let report_path = options.report.clone();
    assert!(run(options).await.unwrap());
    let serialized = std::fs::read_to_string(&report_path).unwrap();
    let report: Value = serde_json::from_str(&serialized).unwrap();
    assert_eq!(report["schema_version"], 1);
    assert_eq!(report["suite"], "farhelm-model-smoke-v1");
    assert_eq!(report["deployment_id"], "fixture-base-adapter-runtime-v1");
    assert_eq!(report["configured_model"]["alias"], ALIAS);
    assert_eq!(report["configured_model"]["data_location"], "local");
    assert_eq!(report["configured_model"]["model"], "fixture-code-base");
    assert_eq!(
        report["configured_model"]["configuration_sha256"]
            .as_str()
            .unwrap()
            .len(),
        64
    );
    assert_eq!(report["passed"], true);
    assert_eq!(report["recorded_api_cost_usd"], 0.0);
    assert_eq!(report["cases"].as_array().unwrap().len(), 3);
    assert_eq!(fixture.requests().len(), 5);
    assert_no_content_leak(&serialized);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&report_path)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
}
