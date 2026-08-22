//! Farhelm runner daemon.
//!
//! Shipped: the SQLite store, the cost ledger, the `PLAN.md` executor, and the
//! localhost HTTP API the phone and web clients read. Still to come: the tmux
//! session manager and hook bridge (M1), the `/v1/complete` gateway pipeline
//! (M2), and the relay link (M3).

use farhelm_sqlite::SqliteStore;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use farhelm_app::id::new_id;
use farhelm_app::ledger::{Call, Ledger};
use farhelm_app::store::{TimeRange, prelude::*};
use farhelm_app::time::now_ms;
use farhelm_domain::BudgetRules as _;
use farhelm_gateway::{AnthropicClient, Gateway, GatewayConfig};
use farhelm_proto::types::{
    Agent, Approval, Avoided, Machine, Repo, Risk, Session, SessionStatus, TaskType, Tier, Usage,
};

use farhelm_runner::state::{self, AppState, ServerEvent};
use farhelm_runner::{api, hook_cli, relay, seed, service, session, terminal};

const USAGE: &str = "\
farhelm — supervise your coding agents from anywhere, and cut what they cost

USAGE:
    farhelm                 where this machine stands, and what is left to do
    farhelm <command> …

SETTING UP
    setup            Every step that is not done yet, asked one at a time and
                     explained. Safe to re-run: it does what is missing and
                     skips what is not. This is the whole quickstart.
    auth             The model credential. With no arguments it signs you in
                     with your subscription, fetching the Anthropic CLI first if
                     it is missing, and stores how to obtain a token — nothing
                     to export and no PATH to get right. --api-key stores a key
                     instead; --status shows what is stored; --forget removes it.
    install-hooks    Register the hook bridge in .claude/settings.json, merging
                     so nothing else in the file is disturbed. Defaults to the
                     repo you are standing in; --global covers every repo on
                     this machine and is the one-and-done option; --print gives
                     you the block to paste.
    login            Join a workspace by asking: prints a short code, waits
                     while you approve it in the web app, stores what it is
                     given. Nothing is copied by hand and it works over SSH.
                     After it, `serve` needs no cloud flags at all.
    logout           Forget those credentials on this machine.
    install-service  A unit file for this machine, with its paths filled in, and
                     the one line that installs it.

RUNNING
    serve            Start the daemon: the API, the fleet, the gateway. --demo
                     runs against a seeded in-memory database with simulated
                     activity and writes nothing to disk.
    doctor           Check a running setup and say what is wrong. Every problem
                     it reports names the command that fixes it. Run this when
                     something is not happening and you cannot see why.
    status           Schema version, sessions and spend, straight from the
                     database. Needs no daemon.
    policy           The destructive-command rules in force. With a command
                     after it, prints how that command would be classified —
                     the way to check a rule you wrote actually fires, short of
                     asking an agent to run something drastic.
    pair             Mint a pairing offer and show it as a QR code.

SERVING OTHERS
    cloud            The control plane: accounts, workspaces, plans, the fleet
                     registry, and the web app. `farhelm cloud --help`.
    relay            Ciphertext fan-out between a runner and its devices, plus
                     WebPush wake-ups it cannot read. `farhelm relay --help`.

OTHER
    hook             Reads a Claude Code hook event on stdin and answers on
                     stdout. Not run by hand — `install-hooks` registers it.
    seed             Write the wireframe fleet into a database file.
    demo             Price a synthetic session and print the ledger summary.
    help             This.

COMMON FLAGS
    --db <path>      --port <port>       --key <path>        --app-dir <path>
    --relay <ws-url> --cloud <url>       --cloud-name <name> --policy <path>
    --terminal tmux|pty                  --mcp-url <https-url>

DEFAULTS
    --db farhelm.db   --port 7842   --key farhelm.key   --app-dir web/dist
    --cloud-file farhelm.cloud.json           (written by `login`, mode 0600)
    --credential-file farhelm.credential.json (written by `auth`, mode 0600)
    --policy farhelm.policy.toml   (optional; the built-in rules stand alone)
    --terminal auto  (tmux when installed, otherwise this process's own PTYs)

    The `forge`-prefixed names these files and variables had before the rename
    are still read when the current one is absent, and say so once when used.

ENVIRONMENT
    FARHELM_CREDENTIAL_COMMAND  a command printing a bearer token, re-run as it
                                expires. `auth` writes this for you.
    ANTHROPIC_API_KEY           enables /v1/complete (a Console key)
    ANTHROPIC_AUTH_TOKEN        a bearer token, read once and never refreshed
    ANTHROPIC_BASE_URL          redirect to a compatible endpoint
    FARHELM_RUNNER_URL          where `hook` reaches the daemon (loopback:7842)
    FARHELM_MACHINE_NAME        overrides the hostname used for this machine
    FARHELM_CLOUD_URL           same as --cloud
    FARHELM_CLOUD_KEY           same as --cloud-key, and the better place for it
                                — a credential on a command line is in every `ps`
    FARHELM_MCP_URL             same as --mcp-url
    FARHELM_TMUX                path to the tmux binary

TERMINAL BACKENDS
    tmux   Panes outlive the daemon and can be attached to by hand. The right
           choice on a server: restarting does not kill an agent mid-task.
    pty    PTYs this process owns. Needs nothing installed and works on Windows,
           but sessions die with the daemon.

REACHABILITY
    On its own the daemon serves loopback only. Enrolled with a control plane it
    appears in your fleet and any device signed into that workspace can reach
    it, over a relay the control plane names — so --relay is not needed
    alongside --cloud. `serve --cloud <url>` on a machine that has never
    enrolled asks to join rather than giving up, then carries straight on into
    serving.

    Asking only happens on a terminal. Under launchd or systemd there is nobody
    to read a code, so a service with no stored credential says so and serves
    loopback rather than blocking.

    Enrolling does not weaken the encryption. Devices still generate their own
    keys and everything still travels sealed between a device and this machine;
    what the control plane provides is a directory and a permission, not a way
    in.
";

const DEFAULT_DB: &str = "farhelm.db";
/// What it was called before the product had one name. See [`farhelm_app::legacy`].
const LEGACY_DB: &str = "forge.db";
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
        // `target/release/farhelm` → the repo root is three up.
        candidates.push(dir.join(DEFAULT_APP_DIR));
        candidates.push(dir.join("..").join(DEFAULT_APP_DIR));
        candidates.push(dir.join("..").join("..").join(DEFAULT_APP_DIR));
        candidates.push(dir.join("..").join("..").join("..").join(DEFAULT_APP_DIR));
    }
    candidates.push(std::path::PathBuf::from("/usr/local/share/farhelm/web"));
    candidates.push(std::path::PathBuf::from("/usr/share/farhelm/web"));

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
const DEFAULT_KEY: &str = "farhelm.key";
/// The identity every paired device already trusts, under its old name.
const LEGACY_KEY: &str = "forge.key";

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
        Some("auth") => auth(&flags, &args[1..]),
        Some("doctor") => doctor(&flags),
        Some("policy") => policy_command(&flags, &args[1..]),
        Some("install-service") => install_service(&flags),
        // The two server halves. They were separate binaries; they are
        // subcommands so that everything this system does is reachable from the
        // one name somebody installed.
        Some("cloud") => farhelm_cloud::cli::run(&args[1..]),
        Some("relay") => farhelm_relay::cli::run(&args[1..]),
        Some("setup") => setup_command(&flags),
        // `help` is the reference; the bare name is the front door. Somebody
        // typing `farhelm` is asking what this is and what to do about it, and
        // a hundred lines of flags answers neither question.
        Some("help") | Some("--help") | Some("-h") => {
            print!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        None => {
            print!("{}", front_door(&flags));
            return ExitCode::SUCCESS;
        }
        Some(unknown) => {
            eprintln!("farhelm: there is no `{unknown}` command.\n");
            eprint!("{}", front_door(&flags));
            return ExitCode::FAILURE;
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

#[derive(Clone)]
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
    /// Where `auth` writes how to obtain a model token, and where `serve`
    /// looks for it.
    credential_file: String,
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
        // An explicit path is taken at face value; an unqualified default
        // resolves through `legacy`, so a machine that was set up before the
        // rename keeps reading the state it already has.
        let defaulted = |flag: Option<String>, new: &str, old: &str| match flag {
            Some(path) => path,
            None => farhelm_app::legacy::state_path(new, old)
                .to_string_lossy()
                .into_owned(),
        };
        Self {
            db: defaulted(value_of("--db"), DEFAULT_DB, LEGACY_DB),
            port: value_of("--port")
                .and_then(|raw| raw.parse().ok())
                .unwrap_or(DEFAULT_PORT),
            demo: args.iter().any(|arg| arg == "--demo"),
            app_dir: value_of("--app-dir"),
            relay: value_of("--relay"),
            cloud: value_of("--cloud")
                .or_else(|| farhelm_app::legacy::env_var("FARHELM_CLOUD_URL")),
            cloud_key: value_of("--cloud-key")
                .or_else(|| farhelm_app::legacy::env_var("FARHELM_CLOUD_KEY")),
            cloud_name: value_of("--cloud-name"),
            cloud_file: defaulted(
                value_of("--cloud-file"),
                farhelm_runner::cloud::DEFAULT_CREDENTIALS_FILE,
                farhelm_runner::cloud::LEGACY_CREDENTIALS_FILE,
            ),
            credential_file: defaulted(
                value_of("--credential-file"),
                farhelm_runner::cloud::DEFAULT_MODEL_CREDENTIAL_FILE,
                farhelm_runner::cloud::LEGACY_MODEL_CREDENTIAL_FILE,
            ),
            mcp_url: value_of("--mcp-url")
                .or_else(|| farhelm_app::legacy::env_var("FARHELM_MCP_URL")),
            terminal: value_of("--terminal"),
            policy: value_of("--policy"),
            key: defaulted(value_of("--key"), DEFAULT_KEY, LEGACY_KEY),
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
        .unwrap_or_else(|_| "farhelm-runner".to_owned());

    if args.iter().any(|arg| arg == "--print") {
        println!("Add this to .claude/settings.json in the repo you want supervised:\n");
        println!("{}", hook_cli::settings_snippet(&binary));
        return Ok(());
    }

    // `--global` writes to ~/.claude/settings.json, which Claude Code reads for
    // every project. That is one setup instead of one per repository, and it is
    // the difference between supervision you have to remember and supervision
    // that is simply on. Per-repo stays the default, because turning it on
    // everywhere is a decision worth typing.
    let settings = if args.iter().any(|arg| arg == "--global") {
        let home = std::env::var("HOME")
            .map(PathBuf::from)
            .map_err(|_| "HOME is not set, so there is no user settings file to write")?;
        home.join(".claude").join("settings.json")
    } else {
        // The repo you are in, unless you name another — the common case is
        // standing in it, and the common case should need no argument.
        args.iter()
            .find(|arg| !arg.starts_with("--"))
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("."))
            .join(".claude")
            .join("settings.json")
    };

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

    let scope = if args.iter().any(|arg| arg == "--global") {
        "every repo on this machine"
    } else {
        "that repo"
    };
    println!(
        "\nEvery tool call Claude Code makes in {scope} now waits for you.\n\
         With the daemon down, hooks defer to Claude Code's own prompt rather \n\
         than blocking — Farhelm being off degrades to plain Claude Code."
    );
    Ok(())
}

/// `farhelm install-service`
///
/// Writes the definition this machine's own service manager understands, and
/// prints the one line that loads it. It used to print a systemd unit on every
/// platform, which meant the answer to "keep it running" on a Mac was a page of
/// text for a service manager that machine does not have.
///
/// It writes the file but does not load it. Writing into your own
/// `~/Library/LaunchAgents` or a unit directory is reversible and inspectable;
/// *starting* a background service that executes agents is the part worth
/// typing yourself, and on Linux it needs a privilege this process should not
/// be asking for.
fn install_service(flags: &Flags) -> Fallible {
    let spec = service::ServiceSpec::detect(flags.relay.clone());
    let manager = service::Manager::detect();
    let path = manager.path(&spec.home);
    let body = match manager {
        service::Manager::Launchd => spec.launchd_plist(),
        service::Manager::Systemd => spec.runner_unit(),
    };

    // Written where it can be written; printed where it cannot. A root-owned
    // unit directory is the ordinary case on Linux, and failing there would be
    // a dead end rather than a step.
    let written = std::path::Path::new(&path)
        .parent()
        .map(|dir| std::fs::create_dir_all(dir).is_ok())
        .unwrap_or(false)
        && std::fs::write(&path, &body).is_ok();

    println!();
    if written {
        println!("  \u{2713} wrote {path}");
    } else {
        println!("  Could not write {path} — here it is to place by hand:");
        println!();
        print!("{body}");
    }

    println!();
    println!("  Then:");
    for line in manager.install_commands(&path).lines() {
        println!("    {line}");
    }
    println!();
    println!(
        "  It runs in {}, so that is where its database and key live.",
        spec.working_dir
    );
    println!(
        "  A model credential goes in {}/farhelm.env, not in the service:",
        spec.working_dir
    );
    println!(
        "    echo 'ANTHROPIC_API_KEY=sk-…' > {}/farhelm.env && chmod 600 {}/farhelm.env",
        spec.working_dir, spec.working_dir
    );
    println!("  — or `farhelm auth`, which stores one without an environment file at all.");
    println!();
    Ok(())
}

/// Which agents this machine can actually start, for the startup banner.
///
/// Printed because "why can I not start Aider" is answered by looking at this
/// line, not by reading the source.
fn installed_agents() -> String {
    let mut available = Vec::new();
    let mut missing = Vec::new();
    for spec in farhelm_domain::agent::AGENTS {
        if spec.binary.is_empty() {
            continue;
        }
        if farhelm_runner::pty::binary_exists(spec.binary) {
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
const DEFAULT_POLICY_PATH: &str = "farhelm.policy.toml";
/// The old name, still read when the new one is absent.
const LEGACY_POLICY_PATH: &str = "forge.policy.toml";

/// Which policy file to read: what `--policy` named, or the default under
/// whichever of its two names is on disk.
fn policy_path(flags: &Flags) -> std::path::PathBuf {
    match flags.policy.as_deref() {
        Some(path) => std::path::PathBuf::from(path),
        None => farhelm_app::legacy::state_path(DEFAULT_POLICY_PATH, LEGACY_POLICY_PATH),
    }
}

/// Load the local destructive-command rules.
///
/// A missing file is fine — the built-ins stand on their own. A *malformed* one
/// is fatal, because somebody wrote a rule in there expecting it to be enforced
/// and starting up without it would be the worst possible outcome.
fn load_policy(flags: &Flags) -> Result<farhelm_domain::risk::Policy, Box<dyn std::error::Error>> {
    let path = policy_path(flags);
    let path = path.as_path();
    if !path.exists() {
        return Ok(farhelm_domain::risk::Policy::default());
    }
    // Reading the file is this binary's job; deciding what the text means is
    // `farhelm-domain`'s, which is why it takes the text rather than the path.
    Ok(farhelm_domain::risk::Policy::parse(
        &std::fs::read_to_string(path)?,
    )?)
}

/// `farhelm policy [<command>...]`
///
/// With no command, prints what is loaded. With one, prints how it would be
/// classified — which is the only way to check that a rule you just wrote
/// actually fires, short of asking an agent to run something destructive.
fn policy_command(flags: &Flags, rest: &[String]) -> Fallible {
    let file = policy_path(flags);
    let path = file.display();
    let policy = load_policy(flags)?;
    let (added, retired) = policy.rule_count();

    if !file.exists() {
        println!("no policy file at {path} — the built-in rules apply on their own");
        println!("\nTo add your own, write this and edit it:\n");
        println!("{}", farhelm_domain::risk::EXAMPLE_POLICY);
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
    let risk = farhelm_domain::risk::classify_with(&policy, "Bash", &command);
    println!("\n{command}");
    println!("  → {risk}");
    match risk {
        farhelm_proto::types::Risk::Destructive => {
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
    let identity = Arc::new(farhelm_crypto::keystore::load_or_create(&flags.key)?);

    // Enrol before anything else that depends on where this machine belongs.
    // Awaited rather than spawned: which relay to dial and which channel to
    // publish on are the control plane's answers, and starting the link on a
    // guess would mean publishing into silence until the first heartbeat landed.
    let cloud_session = match cloud_config_or_ask(&flags).await {
        Some(config) => {
            match farhelm_runner::cloud::enroll_with_retry(&config, identity.public_key().as_str())
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

    let credential_file = flags.credential_file.clone();
    let state = AppState::build_with_policy(
        store,
        |store| {
            // The environment first, so a deployment that already exports a
            // credential keeps working and is not overridden by a file left
            // behind by an experiment. Then what `farhelm auth` stored,
            // which is the path that needs nothing exported by anybody.
            let client = AnthropicClient::from_env().or_else(|| {
                let path = Path::new(&credential_file);
                match farhelm_runner::cloud::ModelCredential::load(path) {
                    Ok(Some(stored)) => Some(AnthropicClient::with_source(
                        farhelm_gateway::credential::CredentialSource::command(stored.command),
                    )),
                    Ok(None) => None,
                    Err(err) => {
                        // Loud: a credential file that exists and cannot be
                        // read is a gateway that will be off for a reason
                        // nobody can see from the banner.
                        eprintln!("  gateway    {}: {err}", path.display());
                        None
                    }
                }
            })?;
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
    let orphaned = farhelm_runner::task::reconcile_after_restart(&state);
    if orphaned > 0 {
        println!(
            "  {orphaned} task(s) were still working when the runner last stopped — \
             marked failed"
        );
    }

    // Started after the state exists, because reconciling the device list on
    // every beat needs the store.
    if let Some((config, session)) = &cloud_session {
        farhelm_runner::cloud::spawn_heartbeat(
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

    println!("farhelm listening on http://{addr}");
    println!("  database   {label}");
    println!("  api        http://{addr}/v1/fleet");
    println!("  events     http://{addr}/v1/events");
    println!("  gateway    {provider}");
    println!("  terminal   {terminal_label}");
    println!("  agents     {}", installed_agents());
    println!(
        "  policy     {}",
        if policy_added == 0 && policy_retired == 0 {
            "built-in rules only (`farhelm policy` to add your own)".to_owned()
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
             \x20            (`pnpm --filter @farhelm/web build`)"
        ),
        Some(dir) => println!("  app        http://{addr}/  (from {})", dir.display()),
        None => println!(
            "  app        not found — run `pnpm --filter @farhelm/web build`,\n\
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
        match farhelm_runner::cloud::fetch_verifier(&cloud_url).await {
            Ok(verifier) => {
                println!("  connector  {mcp_url}/mcp  (org {org_id})");
                app_router = app_router.merge(farhelm_runner::mcp::router(Arc::new(
                    farhelm_runner::mcp::McpState {
                        app: Arc::clone(&state),
                        gate: farhelm_runner::mcp::Gate {
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

    let Some(client) = farhelm_gateway::batch::AnthropicBatchClient::from_env() else {
        // No API key: nothing can be submitted, so the loop would spin for
        // nothing. Queued work stays queued and is flushed once one is set.
        return;
    };

    tokio::spawn(async move {
        let queue = farhelm_gateway::batch::BatchQueue::new(Arc::clone(&state.store), client);
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
fn machine_channel(identity: &farhelm_crypto::Identity) -> String {
    farhelm_proto::channel_for(identity.public_key().as_str())
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
        farhelm_runner::cloud::CloudConfig,
        farhelm_runner::cloud::SharedSession,
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
/// 2. Whatever `farhelm login` wrote. This is the path that makes a fresh
///    install a single command with no secret to copy — see [`login`].
///
/// A URL without a key was once a plausible half-configuration; it is not,
/// because enrolment is the only thing this link does first and it cannot happen
/// anonymously. It is now also unnecessary: `--cloud` alone will use a stored
/// key if there is one.
fn cloud_config(flags: &Flags) -> Option<farhelm_runner::cloud::CloudConfig> {
    let version = env!("CARGO_PKG_VERSION").to_owned();

    if let (Some(base_url), Some(enrollment_key)) = (flags.cloud.clone(), flags.cloud_key.clone()) {
        return Some(farhelm_runner::cloud::CloudConfig {
            base_url,
            enrollment_key,
            name: flags.cloud_name.clone().unwrap_or_else(machine_name),
            version,
        });
    }

    let stored = match farhelm_runner::cloud::Credentials::load(Path::new(&flags.cloud_file)) {
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
        Some(stored) => Some(farhelm_runner::cloud::CloudConfig {
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

/* ------------------------------------------------------------ the front door */

/// What a bare `farhelm` prints: where this machine stands, and the one command
/// that moves it forward.
fn front_door(flags: &Flags) -> String {
    let standing = farhelm_runner::setup::Standing::read(
        Path::new(&flags.db),
        Path::new(&flags.cloud_file),
        Path::new(&flags.credential_file),
    );
    farhelm_runner::setup::front_door(&standing, env!("CARGO_PKG_VERSION"))
}

/// Whether there is a terminal to ask on at all.
///
/// Separate from [`confirm`] because asking is not free: probing by calling
/// `confirm` would print a prompt and consume an answer, so the check for
/// "should I ask anything" would itself have asked something.
fn has_terminal() -> bool {
    std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/tty")
        .is_ok()
}

/// Ask a yes/no question on the terminal, defaulting to yes.
///
/// Reads `/dev/tty` rather than stdin. `setup` is exactly the sort of thing
/// somebody runs from an install script piped into a shell, where stdin *is the
/// rest of the script* — a prompt reading it would swallow the remaining lines
/// and act on them. This is the same care `install.sh` documents for `login`.
///
/// Returns `None` when there is no terminal to ask on, which is the caller's cue
/// to print what it would have done rather than to guess. A setup script that
/// silently chose for you is worse than one that told you what to type.
fn confirm(question: &str) -> Option<bool> {
    use std::io::{BufRead, BufReader, Write};

    let mut tty = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/tty")
        .ok()?;

    write!(tty, "  {question} [Y/n] ").ok()?;
    tty.flush().ok()?;

    let mut answer = String::new();
    BufReader::new(tty.try_clone().ok()?)
        .read_line(&mut answer)
        .ok()?;

    Some(!matches!(
        answer.trim().to_ascii_lowercase().as_str(),
        "n" | "no"
    ))
}

/// Read a line of text on the terminal. `None` for no terminal or an empty answer.
fn ask_for(prompt: &str) -> Option<String> {
    use std::io::{BufRead, BufReader, Write};

    let mut tty = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/tty")
        .ok()?;

    write!(tty, "  {prompt} ").ok()?;
    tty.flush().ok()?;

    let mut answer = String::new();
    BufReader::new(tty.try_clone().ok()?)
        .read_line(&mut answer)
        .ok()?;

    let answer = answer.trim().to_owned();
    (!answer.is_empty()).then_some(answer)
}

/// `farhelm setup` — every remaining step, in the order they block you.
///
/// The steps are the ones `farhelm` with no arguments lists, run rather than
/// printed. Three properties are the whole point:
///
/// **It is resumable.** Each step reads the same state the front door does, so
/// running it twice does the half that failed and skips the half that did not.
/// There is no session, no progress file, and nothing to reset.
///
/// **Every step is refusable.** Declining prints what was skipped and what that
/// costs, and setup carries on. A wizard that cannot be said no to is a wizard
/// people quit, and quitting halfway is the state with no summary.
///
/// **It never runs without a terminal.** Under a pipe or a service manager there
/// is nobody to answer, so it prints the commands it would have run. Guessing
/// on somebody's behalf about credentials and system services is not a
/// convenience.
fn setup_command(flags: &Flags) -> Fallible {
    use farhelm_runner::setup::{Standing, Step};

    let standing = Standing::read(
        Path::new(&flags.db),
        Path::new(&flags.cloud_file),
        Path::new(&flags.credential_file),
    );

    println!();
    println!(
        "  \u{1b}[1mSetting up farhelm\u{1b}[0m in {}",
        std::env::current_dir()?.display()
    );

    let remaining = standing.remaining();
    if remaining.is_empty() {
        println!();
        println!("  Everything is already set up here.");
        println!("  `farhelm serve` starts it; `farhelm doctor` checks a running one.");
        println!();
        return Ok(());
    }

    // No terminal: say what would happen, in order, and stop. This is the
    // branch a CI job and a service manager land in.
    if !has_terminal() {
        println!();
        println!("  No terminal to ask on, so nothing was changed. In order:");
        println!();
        for step in &remaining {
            println!("    {:<32} {}", step.command(), step.why());
        }
        println!();
        return Ok(());
    }

    println!("  {} step(s). Each one can be skipped.", remaining.len());

    let mut skipped: Vec<Step> = Vec::new();
    for step in remaining {
        println!();
        println!("  \u{1b}[1m{}\u{1b}[0m — {}", step.title(), step.why());

        if confirm("Do it now?") != Some(true) {
            skipped.push(step);
            println!("  Skipped. `{}` when you want it.", step.command());
            continue;
        }

        let outcome = match step {
            Step::Credential => auth(flags, &[]),
            Step::Hooks => install_hooks(&["--global".to_owned()]),
            Step::Fleet => match flags
                .cloud
                .clone()
                .or_else(|| ask_for("Control plane URL (blank to skip):"))
            {
                Some(url) => {
                    let mut with_cloud = flags.clone();
                    with_cloud.cloud = Some(url);
                    login(&with_cloud)
                }
                None => {
                    skipped.push(step);
                    println!("  Skipped — no URL given.");
                    continue;
                }
            },
            Step::Service => install_service(flags),
        };

        // A failed step is reported and does not stop the rest. The steps are
        // independent, and abandoning setup because a control plane was
        // unreachable would leave hooks uninstalled for no reason.
        if let Err(err) = outcome {
            println!("  \u{2717} {err}");
            println!("  Left undone. `{}` to retry.", step.command());
            skipped.push(step);
        }
    }

    println!();
    if skipped.is_empty() {
        println!("  \u{2713} All set. `farhelm serve` starts it.");
    } else {
        println!("  Done, with {} left:", skipped.len());
        for step in &skipped {
            println!("    {:<32} {}", step.command(), step.why());
        }
        println!();
        println!("  `farhelm` on its own shows this list again at any time.");
    }
    println!();
    Ok(())
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
        println!("  `farhelm serve` now connects with no further flags.");
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
) -> Result<farhelm_runner::cloud::Credentials, Box<dyn std::error::Error>> {
    use farhelm_runner::cloud::{Credentials, DeviceAnswer};

    let version = env!("CARGO_PKG_VERSION");
    let issued = farhelm_runner::cloud::request_device_code(base_url, name, version).await?;

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

        match farhelm_runner::cloud::poll_device_code(base_url, &issued.device_code).await {
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
            Err(farhelm_runner::cloud::CloudError::Unreachable(_)) => {}
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
async fn cloud_config_or_ask(flags: &Flags) -> Option<farhelm_runner::cloud::CloudConfig> {
    use std::io::IsTerminal as _;

    if let Some(config) = cloud_config(flags) {
        return Some(config);
    }

    let base_url = flags.cloud.clone()?;
    if !std::io::stdin().is_terminal() {
        eprintln!(
            "  cloud      no credential for {base_url}, and nothing is watching to \
             approve one — run `farhelm login --cloud {base_url}` here, or set \
             FORGE_CLOUD_KEY"
        );
        eprintln!("  cloud      continuing on loopback only");
        return None;
    }

    let name = flags.cloud_name.clone().unwrap_or_else(machine_name);
    let path = Path::new(&flags.cloud_file).to_path_buf();
    println!("  cloud      this machine has not joined {base_url} yet.");

    match ask_to_join(&base_url, &name, &path).await {
        Ok(credentials) => Some(farhelm_runner::cloud::CloudConfig {
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

/// Set this machine up to talk to the model provider, in one command.
///
/// Everything this does could be done by hand, and by hand it is three separate
/// things to get right: install a CLI, sign in with it, then tell the daemon
/// where to find it — which means knowing that launchd hands a service its own
/// environment, that the command therefore needs an absolute path, and which of
/// several files that service actually sources. None of those are about running
/// an agent.
///
/// What it deliberately does **not** do is implement a second OAuth client.
/// Whatever tool signed in owns the refresh flow and holds the refresh token in
/// whatever store its platform thinks is right; a login here would be a second
/// place a refresh token lives and a second thing to keep current. So this
/// drives `ant` rather than replacing it — you just never have to think about
/// `ant`.
fn auth(flags: &Flags, args: &[String]) -> Fallible {
    use farhelm_runner::cloud::ModelCredential;

    let path = Path::new(&flags.credential_file).to_path_buf();

    if args.iter().any(|arg| arg == "--status") {
        return match ModelCredential::load(&path)? {
            Some(stored) => {
                println!("  command  {}", stored.command);
                println!("  source   {}", stored.source);
                println!("  file     {}", path.display());
                println!("\n  `farhelm doctor` says whether it still works.");
                Ok(())
            }
            None => {
                println!("Nothing stored. Run `farhelm auth` to set it up.");
                Ok(())
            }
        };
    }

    if args.iter().any(|arg| arg == "--forget") {
        return match std::fs::remove_file(&path) {
            Ok(()) => {
                println!("Removed {}.", path.display());
                println!("The gateway is off until something else supplies a credential.");
                Ok(())
            }
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                println!("Nothing stored at {} — nothing to do.", path.display());
                Ok(())
            }
            Err(err) => Err(err.into()),
        };
    }

    // An API key, for anyone who would rather pay per token than sign in.
    if let Some(index) = args.iter().position(|arg| arg == "--api-key") {
        let key = args
            .get(index + 1)
            .ok_or("--api-key needs the key after it")?
            .trim()
            .to_owned();
        if key.is_empty() {
            return Err("--api-key was given an empty value".into());
        }
        // Stored as a command that prints it, so `serve` has one way of
        // obtaining a credential rather than two code paths.
        ModelCredential {
            command: format!("printf %s {}", shell_quote(&key)),
            source: "an API key given to `farhelm auth --api-key`".into(),
        }
        .save(&path)?;
        println!("Stored an API key in {}.", path.display());
        println!("Restart the runner, and `farhelm doctor` should read green.");
        return Ok(());
    }

    let ant = match locate_ant() {
        Some(found) => {
            println!("  ant        {}", found.display());
            found
        }
        None => {
            println!("  ant        not installed — fetching it");
            install_ant()?
        }
    };

    println!();
    println!("  A browser will open. Sign in with the account whose subscription");
    println!("  you want this machine to use.");
    println!();

    let signed_in = std::process::Command::new(&ant)
        .args(["auth", "login"])
        .status()
        .map_err(|err| format!("could not run {}: {err}", ant.display()))?;
    if !signed_in.success() {
        return Err("that sign-in did not complete — nothing was stored".into());
    }

    // The absolute path, because the daemon's PATH is not the shell's — the
    // single most likely way this works here and fails there. And
    // `--access-token`, because the bare command prints the whole credentials
    // JSON, which becomes an empty Authorization header.
    let command = format!("{} auth print-credentials --access-token", ant.display());

    // Proven before it is stored. A credential command written down without
    // being run is exactly the failure this command exists to remove.
    let probe = std::process::Command::new(&ant)
        .args(["auth", "print-credentials", "--access-token"])
        .output()
        .map_err(|err| format!("could not run {}: {err}", ant.display()))?;
    if !probe.status.success() || probe.stdout.is_empty() {
        return Err(format!(
            "signed in, but `{command}` produced no token — nothing was stored. {}",
            String::from_utf8_lossy(&probe.stderr).trim()
        )
        .into());
    }

    ModelCredential {
        command,
        source: "a subscription, via `ant auth login`".into(),
    }
    .save(&path)?;

    println!();
    println!("  \u{2713} signed in, and a token was obtained.");
    println!("  Stored in {}", path.display());
    println!();
    println!("  Restart the runner and it will use this — nothing to export.");
    Ok(())
}

/// Single-quote a value for a POSIX shell.
fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', r"'\''"))
}

/// Download the Anthropic CLI for this platform and put it on the daemon's PATH.
///
/// Its published asset names do not follow the pattern the install docs build
/// for Linux: macOS ships `..._macos_arm64.zip`, not `..._darwin_arm64.tar.gz`.
/// Constructing the name from `uname` gets a 404 on exactly the platform most
/// people are on, so the release is listed and the asset matched by name.
///
/// `~/.local/bin` because that is where a user-scoped binary belongs and,
/// conveniently, what a service's PATH is usually made to include — but the
/// stored command uses the absolute path regardless, so it does not matter
/// whether it is on anyone's PATH.
fn install_ant() -> Result<PathBuf, Box<dyn std::error::Error>> {
    let arch = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "amd64"
    };
    let (os, extension) = if cfg!(target_os = "macos") {
        ("macos", "zip")
    } else if cfg!(target_os = "linux") {
        ("linux", "tar.gz")
    } else {
        return Err(
            "no published build for this platform — install `ant` by hand, \
                    then run this again"
                .into(),
        );
    };

    let home = std::env::var("HOME").map_err(|_| "HOME is not set")?;
    let bin = PathBuf::from(&home).join(".local").join("bin");
    std::fs::create_dir_all(&bin)?;

    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;

    runtime.block_on(async move {
        let client = reqwest::Client::builder()
            .user_agent("farhelm-runner")
            .build()?;
        let release: serde_json::Value = client
            .get("https://api.github.com/repos/anthropics/anthropic-cli/releases/latest")
            .send()
            .await?
            .json()
            .await?;

        let want = format!("_{os}_{arch}.{extension}");
        let asset = release["assets"]
            .as_array()
            .and_then(|assets| {
                assets.iter().find(|asset| {
                    asset["name"]
                        .as_str()
                        .is_some_and(|name| name.ends_with(&want))
                })
            })
            .ok_or_else(|| format!("no published asset ending in {want}"))?;
        let name = asset["name"].as_str().unwrap_or_default().to_owned();
        let url = asset["browser_download_url"]
            .as_str()
            .ok_or("that asset has no download url")?;

        println!("             {name}");
        let bytes = client.get(url).send().await?.bytes().await?;

        // Checked against the published list. This is a binary about to be run
        // by a daemon; a truncated download that happens to unpack is worse
        // than a failed one.
        if let Some(sums) = release["assets"].as_array().and_then(|assets| {
            assets.iter().find(|asset| {
                asset["name"]
                    .as_str()
                    .is_some_and(|n| n.ends_with("checksums.txt"))
            })
        }) && let Some(sums_url) = sums["browser_download_url"].as_str()
        {
            let listed = client.get(sums_url).send().await?.text().await?;
            let want_sum = listed
                .lines()
                .find(|line| line.ends_with(&name))
                .and_then(|line| line.split_whitespace().next())
                .ok_or("that asset is not in the checksum list")?;
            let got = {
                use sha2::{Digest as _, Sha256};
                format!("{:x}", Sha256::digest(&bytes))
            };
            if got != want_sum {
                return Err(format!("checksum mismatch for {name} — refusing to install").into());
            }
            println!("             checksum verified");
        }

        let staged = bin.join(".ant.download");
        std::fs::write(&staged, &bytes)?;

        // Unpacked with the system tools rather than by linking an archive
        // library into the daemon: this runs once, by hand, and `unzip`/`tar`
        // are present wherever this binary is.
        let unpacked = bin.join(".ant.unpacked");
        let _ = std::fs::remove_dir_all(&unpacked);
        std::fs::create_dir_all(&unpacked)?;
        let ok = if extension == "zip" {
            std::process::Command::new("unzip")
                .args(["-o", "-q"])
                .arg(&staged)
                .arg("-d")
                .arg(&unpacked)
                .status()?
        } else {
            std::process::Command::new("tar")
                .arg("-xzf")
                .arg(&staged)
                .arg("-C")
                .arg(&unpacked)
                .status()?
        };
        if !ok.success() {
            return Err("could not unpack the download".into());
        }

        let extracted = unpacked.join("ant");
        if !extracted.is_file() {
            return Err("the archive did not contain `ant`".into());
        }

        let target = bin.join("ant");
        std::fs::copy(&extracted, bin.join(".ant.new"))?;
        std::fs::rename(bin.join(".ant.new"), &target)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o755))?;
        }
        // Gatekeeper refuses a quarantined binary, and the message it gives
        // says nothing about quarantine.
        #[cfg(target_os = "macos")]
        {
            let _ = std::process::Command::new("xattr")
                .args(["-d", "com.apple.quarantine"])
                .arg(&target)
                .status();
        }

        let _ = std::fs::remove_file(&staged);
        let _ = std::fs::remove_dir_all(&unpacked);
        println!("             installed {}", target.display());
        Ok(target)
    })
}

/// Find `ant`, including where this command would have put it.
fn locate_ant() -> Option<PathBuf> {
    if let Ok(home) = std::env::var("HOME") {
        let local = PathBuf::from(&home).join(".local").join("bin").join("ant");
        if local.is_file() {
            return Some(local);
        }
    }
    let output = std::process::Command::new("sh")
        .args(["-c", "command -v ant"])
        .output()
        .ok()?;
    let path = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    (output.status.success() && !path.is_empty()).then(|| PathBuf::from(path))
}

/// Say what is wrong with this setup, and the one command that fixes each thing.
///
/// Written after watching every individual piece report success while the thing
/// as a whole did nothing. A machine can be installed, enrolled, online and
/// visible in the fleet, and still be unable to do either of the two things
/// this product does — because a credential is commented out and no hooks are
/// registered. Nothing said so. The banner mentioned both, as facts rather than
/// as problems, twelve lines apart and only at startup.
///
/// The rule here: every failure names the command that fixes it. A check that
/// reports a problem without one is a check that has moved the work rather than
/// done it.
fn doctor(flags: &Flags) -> Fallible {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    runtime.block_on(async move {
        let base = format!("http://127.0.0.1:{}", flags.port);
        let client = reqwest::Client::new();
        let mut problems = 0usize;

        println!();

        // 1. The daemon. Everything else is unknowable without it.
        let status: Option<serde_json::Value> = match client
            .get(format!("{base}/v1/status"))
            .timeout(Duration::from_secs(5))
            .send()
            .await
        {
            Ok(response) if response.status().is_success() => response.json().await.ok(),
            _ => None,
        };

        let Some(status) = status else {
            // Not counted: this branch returns, and the count is only there to
            // total up what the reader can act on below.
            // "No status" has two causes with opposite fixes, and telling them
            // apart matters: a daemon that is up but too old to answer is not
            // a daemon you should be told to start. Health has been there all
            // along, so it separates them.
            let alive = client
                .get(format!("{base}/v1/health"))
                .timeout(Duration::from_secs(5))
                .send()
                .await
                .map(|response| response.status().is_success())
                .unwrap_or(false);

            if alive {
                bad("runner", "running, but too old to answer /v1/status");
                fix("./deploy/redeploy.sh runner  (or reinstall and restart it)");
                println!();
                println!("  The rest cannot be checked until it is on a build that reports.");
            } else {
                bad("runner", &format!("not answering on {base}"));
                fix(&format!("farhelm serve --port {}", flags.port));
                println!();
                println!("  Nothing else can be checked until it is up.");
            }
            return Ok(());
        };
        good("runner", &format!("listening on {base}"));

        // 2. Reachable from anywhere, or from this machine's browser only.
        match status.get("relay").and_then(|v| v.as_str()) {
            Some(url) => good("fleet", &format!("connected · {url}")),
            None => {
                problems += 1;
                bad("fleet", "loopback only — no phone can reach this machine");
                fix("farhelm login --cloud <url>, then restart the runner");
            }
        }

        // 3. The gateway. Without it agent tasks cannot run at all.
        let credential_error = status
            .get("credential_error")
            .and_then(|v| v.as_str())
            .filter(|why| !why.is_empty());

        if let Some(why) = credential_error {
            // Configured, and unusable. Worth its own message: "gateway off"
            // would send you looking for a setting that is already set.
            problems += 1;
            bad("gateway", "configured, but no credential can be obtained");
            println!("                  {why}");
            fix("ant auth login   (then restart the runner)");
        } else if status.get("gateway").and_then(|v| v.as_bool()) == Some(true) {
            good("gateway", "on — agent tasks can run");
        } else {
            problems += 1;
            bad("gateway", "off — agent tasks cannot run");
            fix("farhelm auth   (or --api-key <key>), then restart the runner");
        }

        // 4. Hooks. The check the daemon cannot do for itself: these live in
        //    the *user's* files, and their absence is silent by construction —
        //    an agent with no hooks simply never calls.
        let home = std::env::var("HOME").ok().map(PathBuf::from);
        let global = home
            .as_ref()
            .map(|home| home.join(".claude").join("settings.json"));
        let here = PathBuf::from(".claude").join("settings.json");
        let installed = |path: &Path| {
            std::fs::read_to_string(path)
                .map(|text| text.contains("farhelm hook") || text.contains("hook\""))
                .unwrap_or(false)
        };

        match (global.as_deref().is_some_and(installed), installed(&here)) {
            (true, _) => good("supervision", "hooks installed for every repo"),
            (false, true) => good("supervision", "hooks installed in this repo only"),
            (false, false) => {
                problems += 1;
                bad(
                    "supervision",
                    "no hooks — nothing an agent does will reach this runner",
                );
                fix("farhelm install-hooks --global");
            }
        }

        // 5. Something to supervise.
        let agents: Vec<&str> = status
            .get("agents")
            .and_then(|v| v.as_array())
            .map(|list| list.iter().filter_map(|a| a.as_str()).collect())
            .unwrap_or_default();
        if agents.is_empty() {
            problems += 1;
            bad("agents", "none installed on this machine");
            fix("install Claude Code — it is the one verified end to end");
        } else {
            good("agents", &agents.join(", "));
        }

        // 6. Has anything ever arrived? A setup that looks right and has never
        //    seen a session usually means hooks in a file the agent does not
        //    read.
        let sessions = status.get("sessions").and_then(|v| v.as_i64()).unwrap_or(0);
        if sessions == 0 {
            println!(
                "  \u{b7} sessions      none yet — start an agent in a repo and it \
                 should appear"
            );
        } else {
            good("sessions", &format!("{sessions} recorded"));
        }

        println!();
        match problems {
            0 => println!("  \u{2713} nothing to fix."),
            1 => println!("  1 problem above. Fix it and run `farhelm doctor` again."),
            n => println!("  {n} problems above, in the order they block you."),
        }
        println!();
        Ok(())
    })
}

fn good(label: &str, detail: &str) {
    println!("  \u{2713} {label:<13} {detail}");
}

fn bad(label: &str, detail: &str) {
    println!("  \u{2717} {label:<13} {detail}");
}

fn fix(command: &str) {
    println!("                  fix: {command}");
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
    farhelm_app::legacy::env_var("FARHELM_MACHINE_NAME")
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
        let offer: farhelm_crypto::PairingOffer = reqwest::Client::new()
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

        println!("Scan from the Farhelm app, or paste this:\n");
        println!("{payload}\n");
        println!(
            "The code is single-use and expires in {} minutes.",
            farhelm_crypto::PAIRING_TTL_MS / 60_000
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
        tmux_target: Some("farhelm:3.1".into()),
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
    /// Both this binary and the Tauri app now call `farhelm_proto::channel_for`,
    /// but each keeps its own copy of this assertion: they can be pointed at one
    /// `forge.key`, and the failure mode if they ever diverge again is silence —
    /// the runner publishes on a channel no paired device is listening to, and
    /// nothing anywhere reports an error.
    #[test]
    fn the_channel_rule_is_the_one_the_desktop_app_uses() {
        let identity = farhelm_crypto::Identity::from_secret_base64(
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
                std::env::temp_dir().join(format!("farhelm-appdir-{name}-{}", std::process::id()));
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
