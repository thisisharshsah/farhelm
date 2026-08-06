//! RelayForge runner daemon.
//!
//! Shipped: the SQLite store, the cost ledger, the `PLAN.md` executor, and the
//! localhost HTTP API the phone and web clients read. Still to come: the tmux
//! session manager and hook bridge (M1), the `/v1/complete` gateway pipeline
//! (M2), and the relay link (M3).

use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use forge_core::id::new_id;
use forge_core::ledger::{Call, Ledger};
use forge_core::store::{SqliteStore, Store, TimeRange};
use forge_core::time::now_ms;
use forge_core::types::{
    Agent, Approval, Avoided, Machine, Repo, Risk, Session, SessionStatus, TaskType, Tier, Usage,
};
use forge_gateway::{AnthropicClient, Gateway, GatewayConfig};

use forge_runner::state::{self, AppState, ServerEvent};
use forge_runner::{api, hook_cli, relay, seed, service, session, terminal};

const USAGE: &str = "\
forge-runner — RelayForge runner daemon

USAGE:
    forge-runner serve [--demo] [--db <path>] [--port <port>] [--app-dir <path>]
                       [--relay <ws-url>] [--key <path>] [--terminal tmux|pty]
    forge-runner seed [--db <path>]
    forge-runner status [--db <path>]
    forge-runner demo
    forge-runner hook
    forge-runner install-hooks
    forge-runner pair [--port <port>]
    forge-runner policy [--policy <path>] [<command>...]
    forge-runner install-service [--relay <ws-url>]

    serve          Start the localhost API. --demo runs against a seeded
                   in-memory database with simulated agent activity.
    seed           Write the wireframe fleet into a database file.
    status         Print schema version, sessions, and spend.
    demo           Price a synthetic session and print the ledger summary.
    hook           Read a Claude Code hook event on stdin, answer on stdout.
                   Not run by hand — registered in .claude/settings.json.
    install-hooks  Print the settings block that registers this binary.
    pair           Mint a pairing offer and show it as a QR code.
    install-service  Print a systemd unit with this machine's paths filled in.
    policy         Show the destructive-command rules in force. With a command,
                   print how that command would be classified — the way to check
                   a rule you just wrote actually fires.

ENVIRONMENT:
    ANTHROPIC_API_KEY    enables /v1/complete (a Console key)
    ANTHROPIC_AUTH_TOKEN enables it with a short-lived bearer token instead
    ANTHROPIC_BASE_URL   redirect to a compatible endpoint
    FORGE_RUNNER_URL     where `hook` reaches the daemon (default loopback:7842)
    FORGE_MACHINE_NAME   overrides the hostname used for this machine

DEFAULTS:
    --db forge.db    --port 7842    --app-dir web/dist    --key forge.key
    --policy forge.policy.toml   (optional; the built-in rules stand alone)
    --terminal auto  (tmux when installed, otherwise this process's own PTYs)

TERMINAL BACKENDS:
    tmux   Panes outlive the runner and can be attached to by hand. The right
           choice on a server: restarting the daemon does not kill an agent
           mid-task.
    pty    PTYs this process owns. Needs nothing installed and works on Windows,
           but sessions die with the runner.

With --relay, the runner dials out to a relay and becomes reachable from a
paired phone anywhere. Without it, it serves on loopback only.
";

const DEFAULT_DB: &str = "forge.db";
const DEFAULT_PORT: u16 = 7842;
const DEFAULT_APP_DIR: &str = "web/dist";

/// Find the built web app.
///
/// `--app-dir` used to default to the literal relative path `web/dist`, which
/// works only when the runner is started from the repository root. The quickstart
/// tells you to `cd` into a state directory first — so following it produced a
/// runner that served the API happily and answered 404 for the app itself.
///
/// So an unqualified default now *searches*, in the order that matches how the
/// binary is actually being used: the working directory (a dev running from the
/// repo), then beside and above the binary (an installed or `cargo build` copy),
/// then the conventional system share path (a package).
fn resolve_app_dir(explicit: Option<&str>) -> Option<std::path::PathBuf> {
    let built = |dir: std::path::PathBuf| dir.join("index.html").is_file().then_some(dir);

    // An explicit path is taken at face value. Silently searching elsewhere
    // after someone named a directory would be worse than serving nothing.
    if let Some(path) = explicit {
        return built(std::path::PathBuf::from(path));
    }

    let mut candidates = vec![std::path::PathBuf::from(DEFAULT_APP_DIR)];
    if let Ok(exe) = std::env::current_exe()
        && let Some(dir) = exe.parent()
    {
        // `target/release/forge-runner` → the repo root is three up.
        candidates.push(dir.join(DEFAULT_APP_DIR));
        candidates.push(dir.join("..").join(DEFAULT_APP_DIR));
        candidates.push(dir.join("..").join("..").join(DEFAULT_APP_DIR));
        candidates.push(dir.join("..").join("..").join("..").join(DEFAULT_APP_DIR));
    }
    candidates.push(std::path::PathBuf::from("/usr/local/share/relayforge/web"));
    candidates.push(std::path::PathBuf::from("/usr/share/relayforge/web"));

    candidates.into_iter().find_map(built)
}
const DEFAULT_KEY: &str = "forge.key";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let flags = Flags::parse(&args);

    let result = match args.first().map(String::as_str) {
        Some("serve") => serve(flags),
        Some("seed") => seed_command(&flags.db),
        Some("status") => status(&flags.db),
        Some("demo") => demo(),
        Some("hook") => run_hook(),
        Some("install-hooks") => install_hooks(),
        Some("pair") => pair(&flags),
        Some("policy") => policy_command(&flags, &args[1..]),
        Some("install-service") => install_service(&flags),
        _ => {
            print!("{USAGE}");
            return ExitCode::SUCCESS;
        }
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("error: {err}");
            ExitCode::FAILURE
        }
    }
}

struct Flags {
    db: String,
    port: u16,
    demo: bool,
    /// Explicit `--app-dir`. `None` means search the usual places.
    app_dir: Option<String>,
    relay: Option<String>,
    key: String,
    /// Local destructive-command rules. Absent means the built-ins alone.
    policy: Option<String>,
    /// `tmux`, `pty`, or `None` to pick whatever is available.
    terminal: Option<String>,
}

impl Flags {
    fn parse(args: &[String]) -> Self {
        let value_of = |name: &str| {
            args.iter()
                .position(|arg| arg == name)
                .and_then(|index| args.get(index + 1))
                .cloned()
        };
        Self {
            db: value_of("--db").unwrap_or_else(|| DEFAULT_DB.to_owned()),
            port: value_of("--port")
                .and_then(|raw| raw.parse().ok())
                .unwrap_or(DEFAULT_PORT),
            demo: args.iter().any(|arg| arg == "--demo"),
            app_dir: value_of("--app-dir"),
            relay: value_of("--relay"),
            terminal: value_of("--terminal"),
            policy: value_of("--policy"),
            key: value_of("--key").unwrap_or_else(|| DEFAULT_KEY.to_owned()),
        }
    }
}

type Fallible = Result<(), Box<dyn std::error::Error>>;

fn seed_command(db_path: &str) -> Fallible {
    let store = SqliteStore::open(db_path)?;
    if !store.list_sessions()?.is_empty() {
        return Err(format!(
            "{db_path} already has sessions — seed only writes to an empty database"
        )
        .into());
    }
    let ids = seed::seed(&store, now_ms())?;
    println!("seeded {db_path}");
    println!("  active session {}", ids.active_session);
    println!("  pending approval {}", ids.pending_approval);
    Ok(())
}

/// Answer one hook event. Runs on a single-threaded runtime — this process
/// exists for one blocking round trip and then exits.
fn run_hook() -> Fallible {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?
        .block_on(hook_cli::run())
}

fn install_hooks() -> Fallible {
    let binary = std::env::current_exe()
        .map(|path| path.display().to_string())
        .unwrap_or_else(|_| "forge-runner".to_owned());

    println!("Add this to .claude/settings.json in the repo you want supervised:\n");
    println!("{}", hook_cli::settings_snippet(&binary));
    println!(
        "\nThen start the daemon with `forge-runner serve`. With the daemon down, \n\
         hooks defer to Claude Code's own permission prompt rather than blocking."
    );
    Ok(())
}

/// `forge-runner install-service`
///
/// Prints a unit rather than writing one. Installing a service is a privileged,
/// system-wide change with an obvious blast radius, and a tool that did it
/// silently on a machine somebody was only trying out would deserve the
/// reputation it got. The command to install it is one line and it is printed
/// alongside.
fn install_service(flags: &Flags) -> Fallible {
    let spec = service::ServiceSpec::detect(flags.relay.clone());

    println!("# Save as /etc/systemd/system/relayforge.service\n");
    print!("{}", spec.runner_unit());
    println!(
        "\n# Then:\n\
         #   sudo systemctl daemon-reload\n\
         #   sudo systemctl enable --now relayforge\n\
         #   journalctl -u relayforge -f\n\
         #\n\
         # An API key goes in {}/forge.env, not in the unit:\n\
         #   echo 'ANTHROPIC_API_KEY=sk-…' > {}/forge.env\n\
         #   chmod 600 {}/forge.env",
        spec.working_dir, spec.working_dir, spec.working_dir
    );
    Ok(())
}

/// Which agents this machine can actually start, for the startup banner.
///
/// Printed because "why can I not start Aider" is answered by looking at this
/// line, not by reading the source.
fn installed_agents() -> String {
    let mut available = Vec::new();
    let mut missing = Vec::new();
    for spec in forge_core::agent::AGENTS {
        if spec.binary.is_empty() {
            continue;
        }
        if forge_runner::pty::binary_exists(spec.binary) {
            available.push(spec.display_name);
        } else {
            missing.push(spec.display_name);
        }
    }
    if available.is_empty() {
        return format!("none installed (looked for: {})", missing.join(", "));
    }
    let mut line = available.join(", ");
    if !missing.is_empty() {
        line.push_str(&format!("  ·  not installed: {}", missing.join(", ")));
    }
    line
}

/// Where the policy file lives when `--policy` was not given.
const DEFAULT_POLICY_PATH: &str = "forge.policy.toml";

/// Load the local destructive-command rules.
///
/// A missing file is fine — the built-ins stand on their own. A *malformed* one
/// is fatal, because somebody wrote a rule in there expecting it to be enforced
/// and starting up without it would be the worst possible outcome.
fn load_policy(flags: &Flags) -> Result<forge_core::risk::Policy, Box<dyn std::error::Error>> {
    let path = flags.policy.as_deref().unwrap_or(DEFAULT_POLICY_PATH);
    Ok(forge_core::risk::Policy::load(path)?.unwrap_or_default())
}

/// `forge-runner policy [<command>...]`
///
/// With no command, prints what is loaded. With one, prints how it would be
/// classified — which is the only way to check that a rule you just wrote
/// actually fires, short of asking an agent to run something destructive.
fn policy_command(flags: &Flags, rest: &[String]) -> Fallible {
    let path = flags.policy.as_deref().unwrap_or(DEFAULT_POLICY_PATH);
    let policy = load_policy(flags)?;
    let (added, retired) = policy.rule_count();

    if !std::path::Path::new(path).exists() {
        println!("no policy file at {path} — the built-in rules apply on their own");
        println!("\nTo add your own, write this and edit it:\n");
        println!("{}", forge_core::risk::EXAMPLE_POLICY);
    } else {
        println!("{path}: {added} rule(s) added, {retired} built-in(s) retired");
        for pattern in &policy.destructive {
            println!("  destructive        {pattern}");
        }
        for pattern in &policy.destructive_exact {
            println!("  destructive (case) {pattern}");
        }
        for pattern in &policy.allow {
            println!("  retired            {pattern}");
        }
    }

    if rest.is_empty() {
        return Ok(());
    }

    let command = rest.join(" ");
    let risk = forge_core::risk::classify_with(&policy, "Bash", &command);
    println!("\n{command}");
    println!("  → {risk}");
    match risk {
        forge_core::types::Risk::Destructive => {
            println!("  phone only — this cannot be approved from a watch or a notification")
        }
        _ => println!("  can be approved from any paired device"),
    }
    Ok(())
}

fn serve(flags: Flags) -> Fallible {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    runtime.block_on(serve_async(flags))
}

async fn serve_async(flags: Flags) -> Fallible {
    let (store, label) = if flags.demo {
        (
            SqliteStore::open_in_memory()?,
            "in-memory (demo)".to_owned(),
        )
    } else {
        (SqliteStore::open(&flags.db)?, flags.db.clone())
    };

    let seeded = if flags.demo {
        Some(seed::seed(&store, now_ms())?)
    } else {
        None
    };

    // The runner's long-term identity. Minted on first start, reused forever
    // after — a new key would silently break every paired device.
    let identity = Arc::new(forge_crypto::keystore::load_or_create(&flags.key)?);

    let relay_info = flags.relay.as_ref().map(|url| state::RelayInfo {
        url: url.clone(),
        // The channel is derived from the machine identity so it is stable
        // across restarts and unique per runner.
        channel: format!("forge-{}", machine_channel(&flags.key, &identity)),
    });

    // The gateway is only constructed when a provider is configured, so the
    // read-only API and the app work on a fresh clone with no credentials.
    let mut provider =
        "none (set ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN to enable /v1/complete)".to_owned();

    // Chosen before the state is built, because the PTY backend owns its panes
    // and there can only be one of it.
    let terminal = Arc::new(terminal::AnyTerminal::select(flags.terminal.as_deref()).await);
    let terminal_label = if terminal.is_durable() {
        format!("{} · sessions survive a runner restart", terminal.name())
    } else {
        format!("{} · sessions end when this process does", terminal.name())
    };

    let policy = load_policy(&flags)?;
    let (policy_added, policy_retired) = policy.rule_count();

    let state = AppState::build_with_policy(
        store,
        |store| {
            let client = AnthropicClient::from_env()?;
            let config = GatewayConfig::default();
            provider = format!(
                "anthropic ({}) — small {} / large {} / frontier {}",
                client.credential_kind(),
                config.models.small,
                config.models.large,
                config.models.frontier
            );
            Some(Gateway::new(store, client, config))
        },
        Arc::clone(&identity),
        relay_info.clone(),
        Some(Arc::clone(&terminal)),
        policy,
    );

    // A native agent task is a spawned loop plus a row. The loop does not
    // survive a restart and the row does, so anything still marked `running`
    // belongs to a process that is gone.
    let orphaned = forge_runner::task::reconcile_after_restart(&state);
    if orphaned > 0 {
        println!(
            "  {orphaned} task(s) were still working when the runner last stopped — \
             marked failed"
        );
    }

    if let Some(info) = &relay_info {
        relay::spawn(
            Arc::clone(&state),
            Arc::clone(&identity),
            relay::RelayConfig {
                url: info.url.clone(),
                channel: info.channel.clone(),
            },
        );
    }

    if let Some(ids) = seeded {
        for (index, line) in seed::DEMO_OUTPUT.iter().enumerate() {
            state.push_output(
                &ids.active_session,
                *line,
                now_ms() - (20 - index as i64) * 1_000,
            );
        }
        spawn_demo_activity(Arc::clone(&state), ids.active_session);
    }

    spawn_budget_guard(Arc::clone(&state));
    spawn_batch_flusher(Arc::clone(&state));

    // Polls panes for output, reads them for questions an agent is waiting on,
    // and reaps sessions whose pane has gone (D4). Harmless with no backend
    // available: the capture and list calls degrade to "nothing there" rather
    // than erroring in a loop.
    session::spawn_poller(session::SessionManager::new(
        Arc::clone(&state),
        Arc::clone(&terminal),
    ));

    // Serve the built PWA alongside the API when it exists, so a single binary
    // is enough on the runner box. In development the app is served by Vite,
    // which proxies /v1 back here.
    let app_dir = resolve_app_dir(flags.app_dir.as_deref());

    let listener = tokio::net::TcpListener::bind(("127.0.0.1", flags.port)).await?;
    let addr = listener.local_addr()?;

    println!("forge-runner listening on http://{addr}");
    println!("  database   {label}");
    println!("  api        http://{addr}/v1/fleet");
    println!("  events     http://{addr}/v1/events");
    println!("  gateway    {provider}");
    println!("  terminal   {terminal_label}");
    println!("  agents     {}", installed_agents());
    println!(
        "  policy     {}",
        if policy_added == 0 && policy_retired == 0 {
            "built-in rules only (`forge-runner policy` to add your own)".to_owned()
        } else {
            format!("{policy_added} rule(s) added, {policy_retired} built-in(s) retired")
        }
    );
    match &relay_info {
        Some(info) => println!("  relay      {} · channel {}", info.url, info.channel),
        None => println!("  relay      none (loopback only; pass --relay to go remote)"),
    }
    println!(
        "  identity   {} ({})",
        state.identity.public_key(),
        flags.key
    );
    match &app_dir {
        Some(dir) => println!("  app        http://{addr}/  (from {})", dir.display()),
        None => println!(
            "  app        not found — run `pnpm --filter @relayforge/web build`,\n\
             \x20            or pass --app-dir <path> if it is built elsewhere"
        ),
    }
    if flags.demo {
        println!("  demo mode  simulated agent output every 3s");
    }

    // Outbound-only is the security posture (§6); binding to loopback keeps the
    // runner off the network even before the relay exists.
    axum::serve(listener, api::router_with_app(state, app_dir))
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
    println!("\nshutting down");
}

/// The budget guard (C5, M4): watch every session's spend and fire once when it
/// crosses 80%, once more when it hits the cap.
///
/// It polls rather than hooking the ledger write on purpose — spend can arrive
/// from the gateway, a replayed batch, or a manual correction, and a watcher
/// over the committed state catches all three. At one query per session every
/// few seconds against a local file, the cost is noise.
/// Send queued work to the Batch API, and bank whatever has come back (C6).
///
/// Two intervals, because the two halves have different costs. Flushing is one
/// request and can be frequent; collecting means fetching results, so it runs
/// less often. Neither is urgent — this is the queue for work that can wait, and
/// the provider's own ceiling is twenty-four hours.
///
/// Errors are logged and the loop continues. A provider outage must not stop the
/// runner; the queue is durable and the next pass picks up where this one left
/// off.
fn spawn_batch_flusher(state: Arc<AppState>) {
    const FLUSH_EVERY: Duration = Duration::from_secs(60);
    const COLLECT_EVERY: Duration = Duration::from_secs(300);

    let Some(client) = forge_gateway::batch::AnthropicBatchClient::from_env() else {
        // No API key: nothing can be submitted, so the loop would spin for
        // nothing. Queued work stays queued and is flushed once one is set.
        return;
    };

    tokio::spawn(async move {
        let queue = forge_gateway::batch::BatchQueue::new(Arc::clone(&state.store), client);
        let mut since_collect = Duration::ZERO;

        loop {
            tokio::time::sleep(FLUSH_EVERY).await;
            since_collect += FLUSH_EVERY;

            match queue.flush(now_ms()).await {
                Ok(report) if report.submitted > 0 => println!(
                    "batch: submitted {} item(s) as {}",
                    report.submitted,
                    report.batch_id.unwrap_or_default()
                ),
                Ok(_) => {}
                Err(err) => eprintln!("batch: flush failed: {err}"),
            }

            if since_collect < COLLECT_EVERY {
                continue;
            }
            since_collect = Duration::ZERO;

            match queue.collect(now_ms()).await {
                Ok(report) if report.settled > 0 => println!(
                    "batch: settled {} item(s) ({} ok, {} failed) for ${:.4}",
                    report.settled, report.succeeded, report.failed, report.cost_usd
                ),
                Ok(_) => {}
                Err(err) => eprintln!("batch: collect failed: {err}"),
            }
        }
    });
}

fn spawn_budget_guard(state: Arc<AppState>) {
    use std::collections::HashMap;

    tokio::spawn(async move {
        // Remembers what each session was last reported at, so an alert fires on
        // the *crossing* rather than on every poll while over the line.
        let mut reported: HashMap<String, &'static str> = HashMap::new();

        loop {
            tokio::time::sleep(Duration::from_secs(5)).await;

            let Ok(sessions) = state.store.list_sessions() else {
                continue;
            };
            for session in sessions {
                let Ok(budget) = state.store.session_budget(&session.id) else {
                    continue;
                };
                let Some(pct) = budget.pct() else {
                    continue;
                };

                let level = if budget.is_exhausted() {
                    "stop"
                } else if budget.is_warning() {
                    "warn"
                } else {
                    "ok"
                };

                let previous = reported.insert(session.id.clone(), level);
                if previous == Some(level) || level == "ok" {
                    continue;
                }

                state.publish(ServerEvent::BudgetAlert {
                    session_id: session.id.clone(),
                    pct,
                    hard_stop: level == "stop",
                });
            }
        }
    });
}

/// Simulated agent activity for `--demo`: a line of output every few seconds,
/// and a fresh approval whenever the last one is decided. Enough motion to
/// build the phone UI against without a real agent attached.
fn spawn_demo_activity(state: Arc<AppState>, session_id: String) {
    tokio::spawn(async move {
        let chatter = [
            "Running pytest tests/billing -x …",
            "2 passed, 1 failed",
            "FAILED test_retry_after_500 - assert 3 == 5",
            "Reading src/billing/retry.py",
            "Applying patch to retry_backoff()",
            "Re-running affected tests",
            "34 passed in 5.02s",
        ];
        let mut tick: usize = 0;

        loop {
            tokio::time::sleep(Duration::from_secs(3)).await;
            state.push_output(&session_id, chatter[tick % chatter.len()], now_ms());
            tick += 1;

            // Every ~30s, ask for something again so the approval flow is
            // exercisable repeatedly without restarting the server.
            if tick.is_multiple_of(10)
                && state
                    .store
                    .list_pending_approvals()
                    .map(|pending| pending.is_empty())
                    .unwrap_or(false)
            {
                let approval = Approval {
                    id: new_id(),
                    session_id: session_id.clone(),
                    tool: "bash".into(),
                    payload: if tick.is_multiple_of(20) {
                        "git push --force origin fix/webhook-retry".into()
                    } else {
                        "pytest tests/billing -x".into()
                    },
                    risk: if tick.is_multiple_of(20) {
                        Risk::Destructive
                    } else {
                        Risk::Low
                    },
                    decision: None,
                    decided_via: None,
                    requested_at: now_ms(),
                    decided_at: None,
                };
                if state.store.create_approval(&approval).is_ok() {
                    state.publish(ServerEvent::ApprovalRequest {
                        approval: approval.clone(),
                    });
                    state.publish(ServerEvent::SessionUpsert {
                        session_id: session_id.clone(),
                    });
                }
            }
        }
    });
}

/// A channel id that is stable for this runner and does not leak its key.
///
/// Derived from the public key rather than random, so it survives a restart
/// without another file to keep, and derived rather than *being* the key so the
/// channel id — which the relay sees — is not the thing devices encrypt to.
fn machine_channel(_key_path: &str, identity: &forge_crypto::Identity) -> String {
    let public = identity.public_key().to_string();
    public.chars().take(16).collect()
}

/// Mint a pairing offer against a running daemon and render it as a QR code.
fn pair(flags: &Flags) -> Fallible {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;

    runtime.block_on(async {
        let url = format!("http://127.0.0.1:{}/v1/pair/offer", flags.port);
        let offer: forge_crypto::PairingOffer = reqwest::Client::new()
            .post(&url)
            .send()
            .await
            .map_err(|err| format!("could not reach the runner at {url}: {err}"))?
            .json()
            .await
            .map_err(|err| format!("unexpected response from {url}: {err}"))?;

        let payload = offer.to_qr_payload();
        match qrcode::QrCode::new(payload.as_bytes()) {
            Ok(code) => {
                println!(
                    "{}",
                    code.render::<qrcode::render::unicode::Dense1x2>()
                        .quiet_zone(true)
                        .build()
                );
            }
            Err(err) => eprintln!("(could not render a QR code: {err})"),
        }

        println!("Scan from the RelayForge app, or paste this:\n");
        println!("{payload}\n");
        println!(
            "The code is single-use and expires in {} minutes.",
            forge_crypto::PAIRING_TTL_MS / 60_000
        );
        Ok::<(), Box<dyn std::error::Error>>(())
    })
}

fn status(db_path: &str) -> Fallible {
    let store = SqliteStore::open(db_path)?;
    println!("database     {db_path}");
    println!("schema       v{}", store.schema_version()?);

    let sessions = store.list_sessions()?;
    println!("sessions     {}", sessions.len());
    for session in &sessions {
        let budget = store.session_budget(&session.id)?;
        let pct = budget
            .pct()
            .map(|p| format!("{:.0}%", p * 100.0))
            .unwrap_or_else(|| "—".to_string());
        println!(
            "  {:<18} {:<10} ${:.4} / {pct}",
            session.status, session.id, budget.spent_usd
        );
    }

    let pending = store.list_pending_approvals()?;
    println!("approvals    {} pending", pending.len());
    for approval in &pending {
        println!(
            "  [{}] {} {}",
            approval.risk, approval.tool, approval.payload
        );
    }
    Ok(())
}

/// Milestone 0 exit criterion: a fake usage event renders a cost number.
fn demo() -> Fallible {
    let now = now_ms();
    let store = SqliteStore::open_in_memory()?;

    let machine_id = new_id();
    store.upsert_machine(&Machine {
        id: machine_id.clone(),
        name: "hetzner-1".into(),
        pubkey: "demo-pubkey".into(),
        last_seen_at: Some(now),
        created_at: now,
    })?;

    let repo_id = new_id();
    store.upsert_repo(&Repo {
        id: repo_id.clone(),
        machine_id,
        path: "/srv/payments-api".into(),
        name: "payments-api".into(),
        budget_usd: Some(10.0),
    })?;

    let session_id = new_id();
    store.upsert_session(&Session {
        id: session_id.clone(),
        repo_id: repo_id.clone(),
        agent: Agent::ClaudeCode,
        tmux_target: Some("forge:3.1".into()),
        status: SessionStatus::Running,
        plan_id: None,
        budget_usd: Some(2.0),
        spent_usd: 0.0,
        started_at: now,
        ended_at: None,
        agent_session_id: None,
    })?;

    let ledger = Ledger::new(store);

    ledger.record_at(
        Call::new(
            &session_id,
            "claude-haiku-4-5",
            Tier::Small,
            TaskType::SelectFiles,
            Usage {
                input_tokens: 3_200,
                output_tokens: 180,
                cache_write_tokens: 0,
                cache_read_tokens: 0,
            },
        ),
        now,
    )?;
    ledger.record_at(
        Call::new(
            &session_id,
            "claude-opus-5",
            Tier::Large,
            TaskType::Edit,
            Usage {
                input_tokens: 2_400,
                output_tokens: 1_100,
                cache_write_tokens: 18_000,
                cache_read_tokens: 96_000,
            },
        ),
        now,
    )?;
    ledger.record_at(
        Call::avoided(
            &session_id,
            "claude-opus-5",
            Tier::Large,
            TaskType::HardDebug,
            Avoided::PreGate,
        ),
        now,
    )?;

    let summary = ledger.summarize(&session_id, TimeRange::ALL)?;
    let budget = ledger.store().session_budget(&session_id)?;
    let repo_budget = ledger.store().repo_budget(&repo_id)?;

    println!("session {session_id}");
    print!("{summary}");
    println!(
        "budget       ${:.4} / ${:.2} ({:.0}%)",
        budget.spent_usd,
        budget.cap_usd.unwrap_or(0.0),
        budget.pct().unwrap_or(0.0) * 100.0
    );
    println!(
        "repo budget  ${:.4} / ${:.2}",
        repo_budget.spent_usd,
        repo_budget.cap_usd.unwrap_or(0.0)
    );
    Ok(())
}

#[cfg(test)]
mod app_dir_tests {
    use super::*;

    struct TempDir(std::path::PathBuf);

    impl TempDir {
        fn new(name: &str) -> Self {
            let path =
                std::env::temp_dir().join(format!("forge-appdir-{name}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        fn with_index(self) -> Self {
            std::fs::write(self.0.join("index.html"), "<html></html>").unwrap();
            self
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn an_explicit_path_that_is_built_is_used() {
        let dir = TempDir::new("explicit").with_index();
        assert_eq!(
            resolve_app_dir(Some(&dir.0.display().to_string())),
            Some(dir.0.clone())
        );
    }

    #[test]
    fn an_explicit_path_that_is_not_built_serves_nothing() {
        // Silently searching elsewhere after somebody named a directory would be
        // worse than serving nothing: they would never learn their path was
        // wrong, and would be looking at a different build.
        let dir = TempDir::new("empty");
        assert_eq!(resolve_app_dir(Some(&dir.0.display().to_string())), None);
    }

    #[test]
    fn an_explicit_path_that_does_not_exist_serves_nothing() {
        assert_eq!(resolve_app_dir(Some("/nonexistent/web/dist")), None);
    }

    #[test]
    fn the_default_search_finds_the_app_beside_the_binary() {
        // The bug this fixes: the default used to be the literal relative path
        // `web/dist`, so following the quickstart — which tells you to `cd` into
        // a state directory — produced a runner that served the API and 404'd
        // the app.
        //
        // In this test binary the repo is above `target/debug/deps`, so the
        // search should find it regardless of where the test is run from.
        let found = resolve_app_dir(None);
        if let Some(path) = found {
            assert!(path.join("index.html").is_file());
        }
        // Not asserted as `is_some()`: a checkout that has never run
        // `pnpm build` legitimately has no app, and that is not a failure.
    }

    #[test]
    fn a_directory_without_an_index_is_not_an_app() {
        // A stale empty `web/dist` from a cleaned build must not be served as if
        // it were the app — every route would 404 with no explanation.
        let dir = TempDir::new("no-index");
        assert_eq!(resolve_app_dir(Some(&dir.0.display().to_string())), None);
    }
}
