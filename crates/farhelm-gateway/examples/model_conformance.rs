//! Opt-in synthetic protocol checks through the normal gateway and ledger.
//! No model output is granted filesystem or process execution privileges.

use std::{
    fs::OpenOptions,
    io::Write,
    path::PathBuf,
    process::ExitCode,
    sync::Arc,
    time::{Duration, Instant},
};

use farhelm_app::{
    store::{TimeRange, prelude::*},
    time::now_ms,
};
use farhelm_gateway::{
    CompleteRequest, CompleteResponse, Gateway, GatewayConfig, GatewayError, ModelClient,
    ProviderClient, StableContext, Turn, prompt::ToolResult, providers::ConfiguredDeployment,
    router::Models,
};
use farhelm_proto::types::{Agent, Machine, Repo, Session, SessionStatus, TaskType, Usage};
use farhelm_sqlite::SqliteStore;
use serde::Serialize;
use serde_json::json;

const HELP: &str = "Usage: cargo run -p farhelm-gateway --example model_conformance -- \
--config PATH --model ALIAS --deployment-id ID --report NEW_PATH --run \
[--allow-cloud] [--timeout-seconds 90]\n\nRuns at most five synthetic requests. --run opts in to network inference; a cloud\nentry also needs --allow-cloud. No model downloads or OS tool execution occur.\nReports never overwrite an existing file and contain no prompts or replies.\n";
const EXACT: &str = "FARHELM_CONFORMANCE_OK";
const VALUE: &str = "fixture-value-4829";
const ERROR_REPLY: &str = "TOOL_ERROR_HANDLED";
const SYSTEM: &str = "Follow the synthetic conformance instructions exactly. Use only the declared tool when requested. Never invent its result. After receiving a tool result, reply only with the requested literal. Do not request any other action.";
type ProbeGateway = Gateway<Arc<SqliteStore>, ProviderClient>;

struct Options {
    config: PathBuf,
    model: String,
    deployment_id: String,
    report: PathBuf,
    allow_cloud: bool,
    timeout: Duration,
}

fn options(args: impl IntoIterator<Item = String>) -> Result<Option<Options>, String> {
    let args: Vec<_> = args.into_iter().collect();
    if args == ["--help"] || args == ["-h"] {
        return Ok(None);
    }
    let mut values = std::collections::BTreeMap::new();
    let mut flags = std::collections::BTreeSet::new();
    let mut iter = args.into_iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--run" | "--allow-cloud" => {
                if !flags.insert(arg) {
                    return Err("duplicate option".into());
                }
            }
            "--config" | "--model" | "--deployment-id" | "--report" | "--timeout-seconds" => {
                let value = iter
                    .next()
                    .filter(|v| !v.is_empty() && !v.starts_with("--"))
                    .ok_or_else(|| format!("missing value for {arg}"))?;
                if values.insert(arg, value).is_some() {
                    return Err("duplicate option".into());
                }
            }
            _ => return Err("unknown option; use --help".into()),
        }
    }
    if !flags.contains("--run") {
        return Err("inference is opt-in; supply --run explicitly".into());
    }
    let mut required = |name: &str| values.remove(name).ok_or_else(|| format!("missing {name}"));
    let config = required("--config")?.into();
    let model = required("--model")?;
    let deployment_id = required("--deployment-id")?;
    let report = required("--report")?.into();
    if deployment_id.len() > 128 || deployment_id.chars().any(char::is_control) {
        return Err("deployment ID must contain 1–128 printable bytes".into());
    }
    let seconds = values
        .remove("--timeout-seconds")
        .map(|s| s.parse::<u64>())
        .transpose()
        .map_err(|_| "timeout must be an integer".to_owned())?
        .unwrap_or(90);
    if !(1..=300).contains(&seconds) {
        return Err("timeout must be between 1 and 300 seconds".into());
    }
    Ok(Some(Options {
        config,
        model,
        deployment_id,
        report,
        allow_cloud: flags.contains("--allow-cloud"),
        timeout: Duration::from_secs(seconds),
    }))
}

#[derive(Debug, Serialize)]
struct CallReport {
    stage: &'static str,
    latency_ms: u64,
    model: Option<String>,
    stop_reason: Option<String>,
    usage: Option<Usage>,
    cost_usd: Option<f64>,
    error: Option<&'static str>,
}

#[derive(Debug, Serialize)]
struct CaseReport {
    name: &'static str,
    passed: bool,
    reason: &'static str,
    calls: Vec<CallReport>,
}

#[derive(Serialize)]
struct Report {
    schema_version: u32,
    suite: &'static str,
    deployment_id: String,
    configured_model: ConfiguredDeployment,
    started_at_ms: i64,
    finished_at_ms: i64,
    duration_ms: u64,
    passed: bool,
    cases: Vec<CaseReport>,
    recorded_api_cost_usd: f64,
    limits: [&'static str; 3],
}

fn millis(duration: Duration) -> u64 {
    duration.as_millis().min(u128::from(u64::MAX)) as u64
}

fn gateway(
    client: ProviderClient,
    model: &str,
) -> Result<(ProbeGateway, Arc<SqliteStore>), String> {
    let store = Arc::new(
        SqliteStore::open_in_memory().map_err(|_| "could not open isolated evaluation ledger")?,
    );
    let at = now_ms();
    store
        .upsert_machine(&Machine {
            id: "evaluation-machine".into(),
            name: "synthetic-evaluation".into(),
            pubkey: String::new(),
            last_seen_at: None,
            created_at: at,
        })
        .map_err(|_| "could not seed evaluation machine")?;
    store
        .upsert_repo(&Repo {
            id: "evaluation-repo".into(),
            machine_id: "evaluation-machine".into(),
            path: "synthetic:no-filesystem".into(),
            name: "synthetic-evaluation".into(),
            budget_usd: Some(1.0),
        })
        .map_err(|_| "could not seed evaluation budget")?;
    for name in ["exact_text", "tool_success", "tool_error"] {
        store
            .upsert_session(&Session {
                id: name.into(),
                repo_id: "evaluation-repo".into(),
                agent: Agent::Farhelm,
                tmux_target: None,
                status: SessionStatus::Running,
                plan_id: None,
                budget_usd: Some(1.0),
                spent_usd: 0.0,
                started_at: at,
                ended_at: None,
                agent_session_id: None,
            })
            .map_err(|_| "could not seed evaluation session")?;
    }
    let config = GatewayConfig {
        models: Models {
            small: model.into(),
            large: model.into(),
            frontier: model.into(),
        },
        max_tokens: 256,
        compaction: None,
        ..GatewayConfig::default()
    };
    Ok((Gateway::new(Arc::clone(&store), client, config), store))
}

async fn call(
    gateway: &ProbeGateway,
    request: CompleteRequest,
    stage: &'static str,
    timeout: Duration,
    calls: &mut Vec<CallReport>,
) -> Option<CompleteResponse> {
    let start = Instant::now();
    let outcome = tokio::time::timeout(timeout, gateway.complete(request)).await;
    let (response, error) = match outcome {
        Ok(Ok(response)) => (Some(response), None),
        Ok(Err(GatewayError::BudgetExhausted { .. })) => (None, Some("budget_exhausted")),
        Ok(Err(GatewayError::Dispatch(_))) => (None, Some("provider_error")),
        Ok(Err(_)) => (None, Some("gateway_error")),
        Err(_) => (None, Some("deadline_exceeded")),
    };
    calls.push(CallReport {
        stage,
        latency_ms: millis(start.elapsed()),
        model: response.as_ref().map(|r| r.model.clone()),
        stop_reason: response.as_ref().and_then(|r| r.stop_reason.clone()),
        usage: response.as_ref().map(|r| r.usage),
        cost_usd: response.as_ref().map(|r| r.cost_usd),
        error,
    });
    response
}

fn final_matches(response: &CompleteResponse, expected: &str) -> bool {
    response.refusal.is_none()
        && response.tool_calls.is_empty()
        && matches!(
            response.stop_reason.as_deref(),
            Some("stop" | "end_turn" | "stop_sequence")
        )
        && response.text.trim() == expected
}

fn request(name: &str, instruction: &str, tools: bool) -> CompleteRequest {
    let mut request = CompleteRequest::new(name, TaskType::Edit, instruction);
    request.stable = StableContext {
        system: SYSTEM.into(),
        ..StableContext::default()
    };
    if tools {
        request.stable.tools = vec![
            json!({"name":"lookup_fixture", "description":"Look up a synthetic fixture by its exact key. Wait for the result before replying.", "input_schema":{"type":"object","properties":{"key":{"type":"string","enum":["alpha"]}},"required":["key"],"additionalProperties":false}}),
        ];
    }
    request
}

async fn exact_text(gateway: &ProbeGateway, timeout: Duration) -> CaseReport {
    let mut case = CaseReport {
        name: "exact_text",
        passed: false,
        reason: "request_failed",
        calls: Vec::new(),
    };
    if let Some(response) = call(
        gateway,
        request(
            case.name,
            &format!("Reply with exactly {EXACT} and nothing else. Do not use tools."),
            false,
        ),
        "final",
        timeout,
        &mut case.calls,
    )
    .await
    {
        case.passed = final_matches(&response, EXACT);
        case.reason = if case.passed {
            "passed"
        } else {
            "unexpected_final_response"
        };
    }
    case
}

async fn tool_case(gateway: &ProbeGateway, timeout: Duration, failed: bool) -> CaseReport {
    let name = if failed { "tool_error" } else { "tool_success" };
    let instruction = if failed {
        "Call lookup_fixture exactly once with key alpha. Wait for its result. If the tool result reports an error, reply with exactly TOOL_ERROR_HANDLED. Otherwise reply with its exact content."
    } else {
        "Call lookup_fixture exactly once with key alpha. Wait for its result, then reply with only its exact content."
    };
    let mut request = request(name, instruction, true);
    let mut case = CaseReport {
        name,
        passed: false,
        reason: "request_failed",
        calls: Vec::new(),
    };
    let Some(first) = call(
        gateway,
        request.clone(),
        "tool_request",
        timeout,
        &mut case.calls,
    )
    .await
    else {
        return case;
    };
    if first.refusal.is_some()
        || !matches!(
            first.stop_reason.as_deref(),
            Some("tool_use" | "tool_calls")
        )
        || first.tool_calls.len() != 1
    {
        case.reason = "expected_one_tool_call";
        return case;
    }
    let tool = &first.tool_calls[0];
    if tool.name != "lookup_fixture" || tool.id.is_empty() || tool.input != json!({"key":"alpha"}) {
        case.reason = "unexpected_tool_or_arguments";
        return case;
    }
    // This is an in-memory fixture, never a dispatch to the agent's OS tools.
    request.stable.history = vec![
        Turn::user(first.submitted_instruction),
        // As the agent does: a reasoning model gets its analysis back.
        Turn::assistant_with_tools(first.text, first.tool_calls.clone())
            .with_reasoning(first.reasoning.clone()),
    ];
    request.instruction.clear();
    request.tool_results = vec![ToolResult {
        tool_use_id: tool.id.clone(),
        content: if failed {
            "fixture_unavailable".into()
        } else {
            VALUE.into()
        },
        is_error: failed,
    }];
    if let Some(second) = call(
        gateway,
        request,
        "tool_result_replay",
        timeout,
        &mut case.calls,
    )
    .await
    {
        case.passed = final_matches(&second, if failed { ERROR_REPLY } else { VALUE });
        case.reason = if case.passed {
            "passed"
        } else {
            "unexpected_final_response"
        };
    }
    case
}

async fn evaluate(gateway: &ProbeGateway, timeout: Duration) -> Vec<CaseReport> {
    // Sequential: shared capacity and budgets stay bounded; no automatic retry.
    vec![
        exact_text(gateway, timeout).await,
        tool_case(gateway, timeout, false).await,
        tool_case(gateway, timeout, true).await,
    ]
}

async fn run(options: Options) -> Result<bool, String> {
    let client = ProviderClient::from_path(&options.config).map_err(|err| err.to_string())?;
    let deployment = client
        .deployment(&options.model)
        .map_err(|err| err.to_string())?;
    if deployment.data_location != "local" && !options.allow_cloud {
        return Err("cloud inference also requires --allow-cloud".into());
    }
    if !deployment.tools {
        return Err("the selected deployment must declare tools for this suite".into());
    }
    client
        .model_price(&options.model)
        .map_err(|err| err.to_string())?;
    let (gateway, store) = gateway(client, &options.model)?;
    // Check writability before any inference. create_new refuses existing files
    // and symlinks. A failed write never reports a successful evaluation.
    let mut builder = OpenOptions::new();
    builder.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        builder.mode(0o600);
    }
    let mut file = builder.open(&options.report).map_err(
        |_| "could not create a new private report; check parent directory and existing files",
    )?;
    let started_at_ms = now_ms();
    let start = Instant::now();
    let cases = evaluate(&gateway, options.timeout).await;
    let passed = cases.iter().all(|case| case.passed);
    let recorded_api_cost_usd = store
        .usage_totals(TimeRange::ALL)
        .map_err(|_| "could not summarize evaluation ledger")?
        .cost_usd;
    let report = Report {
        schema_version: 1,
        suite: "farhelm-model-smoke-v1",
        deployment_id: options.deployment_id,
        configured_model: deployment,
        started_at_ms,
        finished_at_ms: now_ms(),
        duration_ms: millis(start.elapsed()),
        passed,
        cases,
        recorded_api_cost_usd,
        limits: [
            "synthetic smoke checks; not release certification",
            "deployment identity is operator-declared; weights and runtime are not attested",
            "timeouts or malformed responses may incur unrecorded upstream charges; local compute is unmetered",
        ],
    };
    serde_json::to_writer_pretty(&mut file, &report)
        .map_err(|_| "could not write evaluation report")?;
    file.write_all(b"\n")
        .and_then(|_| file.sync_all())
        .map_err(|_| "could not flush evaluation report")?;
    for case in &report.cases {
        println!(
            "{}: {} ({})",
            case.name,
            if case.passed { "PASS" } else { "FAIL" },
            case.reason
        );
    }
    println!("Report: {}", options.report.display());
    Ok(passed)
}

#[tokio::main]
async fn main() -> ExitCode {
    match options(std::env::args().skip(1)) {
        Ok(None) => {
            print!("{HELP}");
            ExitCode::SUCCESS
        }
        Ok(Some(options)) => match run(options).await {
            Ok(true) => ExitCode::SUCCESS,
            Ok(false) => ExitCode::FAILURE,
            Err(error) => {
                eprintln!("Conformance probe: {error}");
                ExitCode::FAILURE
            }
        },
        Err(error) => {
            eprintln!("{error}\n{HELP}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
#[path = "support/model_conformance_tests.rs"]
mod tests;
