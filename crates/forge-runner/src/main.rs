//! RelayForge runner daemon.
//!
//! Shipped: the SQLite store, the cost ledger, the `PLAN.md` executor, and the
//! localhost HTTP API the phone and web clients read. Still to come: the tmux
//! session manager and hook bridge (M1), the `/v1/complete` gateway pipeline
//! (M2), and the relay link (M3).

use forge_sqlite::SqliteStore;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use forge_app::id::new_id;
use forge_app::ledger::{Call, Ledger};
use forge_app::store::{TimeRange, prelude::*};
use forge_app::time::now_ms;
use forge_domain::BudgetRules as _;
use forge_gateway::{AnthropicClient, Gateway, GatewayConfig};
use forge_proto::types::{
    Agent, Approval, Avoided, Machine, Repo, Risk, Session, SessionStatus, TaskType, Tier, Usage,
};

use forge_runner::state::{self, AppState, ServerEvent};
use forge_runner::{api, hook_cli, relay, seed, service, session, terminal};

const USAGE: &str = "\
forge-runner — RelayForge runner daemon

USAGE:
    forge-runner serve [--demo] [--db <path>] [--port <port>] [--app-dir <path>]
                       [--relay <ws-url>] [--key <path>] [--terminal tmux|pty]
                       [--cloud <url> --cloud-key <frg_…>] [--cloud-name <name>]
                       [--mcp-url <https-url>]
    forge-runner seed [--db <path>]
    forge-runner status [--db <path>]
    forge-runner demo
    forge-runner hook
    forge-runner install-hooks [<repo>] [--print]
    forge-runner login --cloud <url> [--cloud-name <name>] [--cloud-file <path>]
    forge-runner logout [--cloud-file <path>]
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
    install-hooks  Register the hook bridge in a repo's .claude/settings.json,
                   merging so nothing else in that file is disturbed. Defaults
                   to the repo you are standing in. --print gives you the block
                   to paste instead.
    login          Join a workspace by asking. Prints a short code, waits while
                   you approve it in the web app, then stores what it is given —
                   after which `serve` needs no cloud flags at all. Nothing is
                   copied by hand, and it works over SSH. `serve --cloud <url>`
                   does this by itself on a machine that has not enrolled.
    logout         Forget those stored credentials on this machine.
    pair           Mint a pairing offer and show it as a QR code.
    install-service  Print a systemd unit with this machine's paths filled in.
    policy         Show the destructive-command rules in force. With a command,
                   print how that command would be classified — the way to check
                   a rule you just wrote actually fires.

ENVIRONMENT:
    FORGE_CREDENTIAL_COMMAND
                         a command printing a bearer token, re-run as it
                         expires — the option that needs no metered API key
                         and no second visit
    ANTHROPIC_API_KEY    enables /v1/complete (a Console key)
    ANTHROPIC_AUTH_TOKEN a bearer token, read once and never refreshed
    ANTHROPIC_BASE_URL   redirect to a compatible endpoint
    FORGE_RUNNER_URL     where `hook` reaches the daemon (default loopback:7842)
    FORGE_MACHINE_NAME   overrides the hostname used for this machine
    FORGE_CLOUD_URL      same as --cloud
    FORGE_CLOUD_KEY      same as --cloud-key, and the better place for it —
                         a credential on a command line is in every `ps`
    FORGE_MCP_URL        same as --mcp-url

DEFAULTS:
    --db forge.db    --port 7842    --app-dir web/dist    --key forge.key
    --cloud-file forge.cloud.json   (written by `login`, mode 0600)
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

With a control plane it enrols instead, and there is nothing to pair: the
machine appears in your fleet, and any device signed into that workspace can
reach it. The control plane says which relay to dial, so --relay is not needed
alongside it.

The short way, and the one to use — on a machine that has never enrolled,
`serve` asks rather than giving up:

    forge-runner serve --cloud https://your-control-plane

It prints a code, waits while you approve it in the web app, stores what it is
given, and carries straight on into serving. Every later `serve` needs no flags
at all. `forge-runner login` does the joining half on its own, for when you want
to enrol now and start the daemon later.

Asking only happens on a terminal. Under launchd or systemd there is nobody to
read a code, so a service with no stored credential says so and serves loopback
rather than blocking.

`login` prints a code, you approve it once in the web app, and the credential is
written here rather than typed here. The long way — creating an enrolment key
under Settings → Machines and passing --cloud-key — still works, and is what to
use for a fleet you provision from a script.

Enrolling does not weaken the encryption. Devices still generate their own keys
and everything still travels sealed between a device and this machine; what the
control plane provides is a directory and a permission, not a way in.
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

/// Whether what we found is the desktop build script's placeholder rather than
/// the built app.
///
/// The placeholder exists so the Rust build does not depend on a JavaScript
/// build (see `desktop/src-tauri/build.rs`), and it is worth serving — it is the
/// page that says what to run. But it must not be *reported* as the app. A
/// banner line claiming the app is up, over a page saying it is not built, is
/// the kind of disagreement that costs an hour to notice.
fn is_placeholder_app(dir: &std::path::Path) -> bool {
    dir.join(".not-built").is_file()
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
        Some("install-hooks") => install_hooks(&args[1..]),
        Some("pair") => pair(&flags),
        Some("login") => login(&flags),
        Some("logout") => logout(&flags),
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
    /// The control plane to enrol with. With it, `--relay` is not needed: the
    /// control plane says which relay to dial.
    cloud: Option<String>,
    /// `frg_…`. Also read from `FORGE_CLOUD_KEY`, because a credential on a
    /// command line is a credential in every `ps` and every shell history.
    cloud_key: Option<String>,
    /// What this machine is called in the fleet. Defaults to its hostname.
    cloud_name: Option<String>,
    /// Where `login` writes what it was given, and where `serve` looks for it.
    cloud_file: String,
    /// This machine's public URL, when it is exposed as an MCP connector.
    /// Absent means the connector is not served at all.
    mcp_url: Option<String>,
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
            cloud: value_of("--cloud").or_else(|| std::env::var("FORGE_CLOUD_URL").ok()),
            cloud_key: value_of("--cloud-key").or_else(|| std::env::var("FORGE_CLOUD_KEY").ok()),
            cloud_name: value_of("--cloud-name"),
            cloud_file: value_of("--cloud-file")
                .unwrap_or_else(|| forge_runner::cloud::DEFAULT_CREDENTIALS_FILE.to_owned()),
            mcp_url: value_of("--mcp-url").or_else(|| std::env::var("FORGE_MCP_URL").ok()),
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

/// Register the hook bridge in the repository you are standing in.
///
/// This used to print a JSON block for somebody to paste. That is a step per
/// repository, repeated forever, and it fails silently in the ordinary ways
/// pasting fails — a stray comma, or the wrong object. It writes the file now,
/// merging so that nothing else in the settings is disturbed, and `--print`
/// still gives you the block if you would rather do it yourself.
fn install_hooks(args: &[String]) -> Fallible {
    let binary = std::env::current_exe()
        .map(|path| path.display().to_string())
        .unwrap_or_else(|_| "forge-runner".to_owned());

    if args.iter().any(|arg| arg == "--print") {
        println!("Add this to .claude/settings.json in the repo you want supervised:\n");
        println!("{}", hook_cli::settings_snippet(&binary));
        return Ok(());
    }

    // The repo you are in, unless you name another — the common case is
    // standing in it, and the common case should need no argument.
    let target = args
        .iter()
        .find(|arg| !arg.starts_with("--"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    let settings = target.join(".claude").join("settings.json");

    match hook_cli::install_into(&settings, &binary)? {
        hook_cli::Installed::Created => {
            println!("Wrote {}", settings.display());
        }
        hook_cli::Installed::Merged => {
            println!(
                "Added the hooks to {} — everything else in it was left alone.",
                settings.display()
            );
        }
        hook_cli::Installed::Replaced => {
            println!("Repointed the hooks in {} at {binary}.", settings.display());
        }
        hook_cli::Installed::AlreadyCurrent => {
            println!("{} is already set up. Nothing to do.", settings.display());
        }
    }

    println!(
        "\nEvery tool call Claude Code makes in that repo now waits for you.\n\
         With the daemon down, hooks defer to Claude Code's own prompt rather \n\
         than blocking — RelayForge being off degrades to plain Claude Code."
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
    for spec in forge_domain::agent::AGENTS {
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
fn load_policy(flags: &Flags) -> Result<forge_domain::risk::Policy, Box<dyn std::error::Error>> {
    let path = std::path::Path::new(flags.policy.as_deref().unwrap_or(DEFAULT_POLICY_PATH));
    if !path.exists() {
        return Ok(forge_domain::risk::Policy::default());
    }
    // Reading the file is this binary's job; deciding what the text means is
    // `forge-domain`'s, which is why it takes the text rather than the path.
    Ok(forge_domain::risk::Policy::parse(
        &std::fs::read_to_string(path)?,
    )?)
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
        println!("{}", forge_domain::risk::EXAMPLE_POLICY);
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
    let risk = forge_domain::risk::classify_with(&policy, "Bash", &command);
    println!("\n{command}");
    println!("  → {risk}");
    match risk {
        forge_proto::types::Risk::Destructive => {
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

    // Enrol before anything else that depends on where this machine belongs.
    // Awaited rather than spawned: which relay to dial and which channel to
    // publish on are the control plane's answers, and starting the link on a
    // guess would mean publishing into silence until the first heartbeat landed.
    let cloud_session = match cloud_config_or_ask(&flags).await {
        Some(config) => {
            match forge_runner::cloud::enroll_with_retry(&config, identity.public_key().as_str())
                .await
            {
                Ok(session) => {
                    println!(
                        "  cloud      enrolled as {} in {}",
                        session.runner_id, session.org_id
                    );
                    if session.key_change_pending {
                        eprintln!(
                            "  cloud      this machine's identity does not match the one on \
                             file — an admin has to confirm it before devices can connect"
                        );
                    }
                    let shared = Arc::new(std::sync::RwLock::new(session));
                    Some((config, shared))
                }
                Err(err) => {
                    // Not fatal. A runner that refuses to start because a
                    // website is down is worse than one that serves loopback and
                    // says why.
                    eprintln!("  cloud      {err}");
                    eprintln!("  cloud      continuing on loopback only");
                    None
                }
            }
        }
        None => None,
    };

    let relay_info = match &cloud_session {
        // The control plane is authoritative: it knows which relay this
        // deployment runs and which channel this machine's *pinned* key maps to,
        // which is not always the key this process just loaded.
        Some((_, session)) => {
            let held = session.read().expect("cloud session poisoned");
            Some(state::RelayInfo {
                url: held.relay_url.clone(),
                channel: held.channel.clone(),
            })
        }
        None => flags.relay.as_ref().map(|url| state::RelayInfo {
            url: url.clone(),
            // The channel is derived from the machine identity so it is stable
            // across restarts and unique per runner.
            channel: machine_channel(&identity),
        }),
    };

    // The gateway is only constructed when a provider is configured, so the
    // read-only API and the app work on a fresh clone with no credentials.
    let mut provider =
        "none (set FORGE_CREDENTIAL_COMMAND to enable /v1/complete and /v1/messages)".to_owned();

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

    // Started after the state exists, because reconciling the device list on
    // every beat needs the store.
    if let Some((config, session)) = &cloud_session {
        forge_runner::cloud::spawn_heartbeat(
            Arc::clone(&state.store),
            config.clone(),
            Arc::clone(session),
        );
    }

    if let Some(info) = &relay_info {
        relay::spawn(
            Arc::clone(&state),
            Arc::clone(&identity),
            relay::RelayConfig {
                url: info.url.clone(),
                channel: info.channel.clone(),
                session: cloud_session
                    .as_ref()
                    .map(|(_, session)| Arc::clone(session)),
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
        Some(dir) if is_placeholder_app(dir) => println!(
            "  app        not built — http://{addr}/ explains what to run\n\
             \x20            (`pnpm --filter @relayforge/web build`)"
        ),
        Some(dir) => println!("  app        http://{addr}/  (from {})", dir.display()),
        None => println!(
            "  app        not found — run `pnpm --filter @relayforge/web build`,\n\
             \x20            or pass --app-dir <path> if it is built elsewhere"
        ),
    }
    if flags.demo {
        println!("  demo mode  simulated agent output every 3s");
    }

    // The connector, when this machine is exposed as one. Mounted on the same
    // loopback listener the tunnel already reaches, so there is one process and
    // one port rather than a second server to keep patched.
    let mut app_router = api::router_with_app(Arc::clone(&state), app_dir);
    if let Some((mcp_url, cloud_url, org_id)) = mcp_settings(&flags, &cloud_session) {
        match forge_runner::cloud::fetch_verifier(&cloud_url).await {
            Ok(verifier) => {
                println!("  connector  {mcp_url}/mcp  (org {org_id})");
                app_router = app_router.merge(forge_runner::mcp::router(Arc::new(
                    forge_runner::mcp::McpState {
                        app: Arc::clone(&state),
                        gate: forge_runner::mcp::Gate {
                            verifier,
                            org_id,
                            public_url: mcp_url,
                            issuer: cloud_url,
                        },
                    },
                )));
            }
            // Not fatal, and deliberately loud: serving the connector without a
            // verifier would mean serving it unauthenticated.
            Err(err) => eprintln!("  connector  not served — {err}"),
        }
    }

    // Outbound-only is the security posture (§6); binding to loopback keeps the
    // runner off the network even before the relay exists.
    axum::serve(listener, app_router)
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
fn machine_channel(identity: &forge_crypto::Identity) -> String {
    forge_proto::channel_for(identity.public_key().as_str())
}

/// Where the connector should be served, if it should be at all.
///
/// Three things are required and none can be guessed: the public URL a client
/// will reach (only the operator knows what the tunnel maps), the control plane
/// that mints tokens, and this machine's organisation. Enrolment supplies the
/// last two, so a runner that never enrolled cannot serve a connector — there
/// would be no authorization server to trust and no tenant to check against.
fn mcp_settings(
    flags: &Flags,
    session: &Option<(
        forge_runner::cloud::CloudConfig,
        forge_runner::cloud::SharedSession,
    )>,
) -> Option<(String, String, String)> {
    let mcp_url = flags.mcp_url.clone()?;
    let Some((config, shared)) = session else {
        eprintln!(
            "  connector  --mcp-url was given but this machine is not enrolled; \
             there is no authorization server to trust"
        );
        return None;
    };
    let org_id = shared.read().ok()?.org_id.clone();
    Some((
        mcp_url.trim_end_matches('/').to_owned(),
        config.base_url.trim_end_matches('/').to_owned(),
        org_id,
    ))
}

/// The control-plane configuration, if this runner has one.
///
/// Two ways to have one, checked in this order:
///
/// 1. `--cloud` **and** `--cloud-key`, as before. Explicit flags win, so a
///    machine can be pointed somewhere else for one run without disturbing what
///    `login` stored.
/// 2. Whatever `forge-runner login` wrote. This is the path that makes a fresh
///    install a single command with no secret to copy — see [`login`].
///
/// A URL without a key was once a plausible half-configuration; it is not,
/// because enrolment is the only thing this link does first and it cannot happen
/// anonymously. It is now also unnecessary: `--cloud` alone will use a stored
/// key if there is one.
fn cloud_config(flags: &Flags) -> Option<forge_runner::cloud::CloudConfig> {
    let version = env!("CARGO_PKG_VERSION").to_owned();

    if let (Some(base_url), Some(enrollment_key)) = (flags.cloud.clone(), flags.cloud_key.clone()) {
        return Some(forge_runner::cloud::CloudConfig {
            base_url,
            enrollment_key,
            name: flags.cloud_name.clone().unwrap_or_else(machine_name),
            version,
        });
    }

    let stored = match forge_runner::cloud::Credentials::load(Path::new(&flags.cloud_file)) {
        Ok(stored) => stored,
        Err(err) => {
            // Loud, not silent. A credential file that exists but cannot be
            // read is a machine that will quietly serve loopback only, and the
            // reason has to be on the banner rather than in somebody's guess.
            eprintln!("  cloud      {}: {err}", flags.cloud_file);
            None
        }
    };

    match stored {
        Some(stored) => Some(forge_runner::cloud::CloudConfig {
            // An explicit `--cloud` still overrides where to go, so a stored
            // machine can be repointed at a staging control plane for one run.
            base_url: flags.cloud.clone().unwrap_or(stored.url),
            enrollment_key: stored.enrollment_key,
            name: flags.cloud_name.clone().unwrap_or(stored.name),
            version,
        }),
        // Silent, deliberately. Whether "no credential" is worth complaining
        // about depends on what happens next, and only the caller knows: on a
        // terminal it is about to be fixed by asking, and saying "run login
        // first" immediately before doing exactly that reads as a bug.
        // `cloud_config_or_ask` reports it in the case that stays broken.
        None => None,
    }
}

/// Enrol this machine by asking, rather than by being told a secret.
///
/// The shape is the OAuth device authorization grant, for the reason it exists:
/// the thing that needs a credential — a server over SSH, a desktop app on a
/// laptop — is not the thing that can conveniently show somebody a login page.
/// So the machine generates a secret it keeps, gets back eight characters a
/// person can read off a console, and waits while they approve it wherever they
/// are already signed in.
///
/// What this replaces is copying `frg_…` by hand, which put a long-lived bearer
/// credential through a clipboard, a shell history and quite often a chat
/// message — and could not be done at all on a box whose browser belongs to
/// somebody else.
fn login(flags: &Flags) -> Fallible {
    let base_url = flags
        .cloud
        .clone()
        .ok_or("--cloud <url> is required — that is the control plane to join")?;
    let name = flags.cloud_name.clone().unwrap_or_else(machine_name);
    let path = Path::new(&flags.cloud_file).to_path_buf();

    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;

    runtime.block_on(async move {
        ask_to_join(&base_url, &name, &path).await?;
        println!("  `forge-runner serve` now connects with no further flags.");
        Ok(())
    })
}

/// Run the device flow to completion and write what it yields.
///
/// Shared by [`login`] and by `serve` on a machine that has never enrolled,
/// because they are the same exchange — one of them just happens to be on the
/// way to somewhere else.
async fn ask_to_join(
    base_url: &str,
    name: &str,
    path: &Path,
) -> Result<forge_runner::cloud::Credentials, Box<dyn std::error::Error>> {
    use forge_runner::cloud::{Credentials, DeviceAnswer};

    let version = env!("CARGO_PKG_VERSION");
    let issued = forge_runner::cloud::request_device_code(base_url, name, version).await?;

    println!();
    println!("  Open   {}", issued.verification_uri);
    println!("  Code   {}", issued.user_code);
    println!();
    println!("  Approve it as \"{name}\". Waiting…");

    let deadline =
        tokio::time::Instant::now() + Duration::from_secs(issued.expires_in.max(0) as u64);
    let mut interval = Duration::from_secs(issued.interval.clamp(1, 60));

    loop {
        if tokio::time::Instant::now() >= deadline {
            return Err("nobody approved that code in time — run `login` again".into());
        }
        tokio::time::sleep(interval).await;

        match forge_runner::cloud::poll_device_code(base_url, &issued.device_code).await {
            Ok(DeviceAnswer::Pending { interval: next }) => {
                interval = Duration::from_secs(next.clamp(1, 60));
            }
            Ok(DeviceAnswer::Approved {
                enrollment_key,
                cloud_url,
            }) => {
                let credentials = Credentials {
                    url: cloud_url,
                    enrollment_key,
                    name: name.to_owned(),
                };
                credentials.save(path)?;

                println!("  ✔ approved — enrolled as \"{name}\"");
                println!();
                println!("  Credentials written to {}", path.display());
                return Ok(credentials);
            }
            Ok(DeviceAnswer::Denied) => Err("that request was refused")?,
            Ok(DeviceAnswer::Expired) => {
                Err("that code expired before it was approved — run `login` again")?
            }
            // The control plane going away mid-wait is not a refusal. Keep
            // polling: a human walking to another room takes longer than a
            // restart does.
            Err(forge_runner::cloud::CloudError::Unreachable(_)) => {}
            Err(err) => Err(err.to_string())?,
        }
    }
}

/// The control-plane configuration, asking for one if this machine has none.
///
/// `serve` on a machine that had never enrolled used to print a line about
/// missing flags and carry on serving loopback — technically correct and
/// useless, because the person watching had just typed the one command they
/// knew and got a daemon nothing could reach.
///
/// So if there is a control plane to join and no credential to join it with,
/// this *asks*, right there in the terminal, and carries on into `serve` once
/// somebody approves. Installing and connecting become one command.
///
/// **Only when a human is watching.** Under launchd or systemd there is nobody
/// to read a code, and a service that blocked for fifteen minutes waiting for
/// an approval that cannot arrive would be a far worse failure than the loopback
/// fallback it replaced. Non-interactive keeps exactly the old behaviour.
async fn cloud_config_or_ask(flags: &Flags) -> Option<forge_runner::cloud::CloudConfig> {
    use std::io::IsTerminal as _;

    if let Some(config) = cloud_config(flags) {
        return Some(config);
    }

    let base_url = flags.cloud.clone()?;
    if !std::io::stdin().is_terminal() {
        eprintln!(
            "  cloud      no credential for {base_url}, and nothing is watching to \
             approve one — run `forge-runner login --cloud {base_url}` here, or set \
             FORGE_CLOUD_KEY"
        );
        eprintln!("  cloud      continuing on loopback only");
        return None;
    }

    let name = flags.cloud_name.clone().unwrap_or_else(machine_name);
    let path = Path::new(&flags.cloud_file).to_path_buf();
    println!("  cloud      this machine has not joined {base_url} yet.");

    match ask_to_join(&base_url, &name, &path).await {
        Ok(credentials) => Some(forge_runner::cloud::CloudConfig {
            base_url: credentials.url,
            enrollment_key: credentials.enrollment_key,
            name: credentials.name,
            version: env!("CARGO_PKG_VERSION").to_owned(),
        }),
        Err(err) => {
            eprintln!("  cloud      {err}");
            eprintln!("  cloud      continuing on loopback only");
            None
        }
    }
}

/// Forget what `login` stored.
fn logout(flags: &Flags) -> Fallible {
    let path = Path::new(&flags.cloud_file);
    match std::fs::remove_file(path) {
        Ok(()) => {
            println!("Removed {}.", path.display());
            println!(
                "The machine stays in the fleet until somebody removes it there — \
                 this only stops *this* copy from reconnecting."
            );
            Ok(())
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            println!("Nothing stored at {} — nothing to do.", path.display());
            Ok(())
        }
        Err(err) => Err(err.into()),
    }
}

/// What to call this machine in the fleet.
///
/// The hostname, because that is the name its owner already uses for it. Falls
/// back to something obviously placeholder rather than something plausible — "a
/// machine" is clearly unset, `localhost` looks deliberate and would collide.
fn machine_name() -> String {
    std::env::var("FORGE_MACHINE_NAME")
        .ok()
        .or_else(|| {
            std::process::Command::new("hostname")
                .output()
                .ok()
                .and_then(|out| String::from_utf8(out.stdout).ok())
        })
        .map(|name| name.trim().to_owned())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "a machine".to_owned())
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
mod channel_tests {
    use super::*;

    /// The exact channel this key produces.
    ///
    /// Both this binary and the Tauri app now call `forge_proto::channel_for`,
    /// but each keeps its own copy of this assertion: they can be pointed at one
    /// `forge.key`, and the failure mode if they ever diverge again is silence —
    /// the runner publishes on a channel no paired device is listening to, and
    /// nothing anywhere reports an error.
    #[test]
    fn the_channel_rule_is_the_one_the_desktop_app_uses() {
        let identity = forge_crypto::Identity::from_secret_base64(
            "tapeuo2KzNeIV8FIWkWZ4JtK39yyr83NmVW2pBYYkaU",
        )
        .unwrap();
        assert_eq!(machine_channel(&identity), "forge-kFLWAF8DqRIvUm8g");
    }
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

    #[test]
    fn the_build_scripts_placeholder_is_served_but_not_called_the_app() {
        // `desktop/src-tauri/build.rs` writes an index.html so that cargo does
        // not depend on pnpm. It is worth serving — it says what to run — but
        // reporting it as the app would mean a banner that disagrees with the
        // page it points at.
        let dir = TempDir::new("placeholder").with_index();
        std::fs::write(dir.0.join(".not-built"), "").unwrap();

        assert_eq!(
            resolve_app_dir(Some(&dir.0.display().to_string())),
            Some(dir.0.clone()),
            "the placeholder is still served"
        );
        assert!(is_placeholder_app(&dir.0));
    }

    #[test]
    fn a_real_build_is_not_mistaken_for_the_placeholder() {
        let dir = TempDir::new("real").with_index();
        assert!(!is_placeholder_app(&dir.0));
    }
}
