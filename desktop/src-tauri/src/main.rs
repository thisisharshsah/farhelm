#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! RelayForge desktop.
//!
//! The same runner, on any computer, with a window instead of a terminal.
//!
//! # What this is for
//!
//! `forge-runner serve` assumes a box you already administer: a shell, tmux
//! installed, a systemd unit, a spare terminal to read the startup banner in.
//! That is the right shape for a VPS and the wrong shape for the laptop you
//! actually write code on, and it is unavailable on Windows.
//!
//! This is the same daemon — literally the same library, the same API, the same
//! approval rules — hosted in a window. Install it on a machine and that machine
//! becomes a supervised agent host you can reach from your phone.
//!
//! # What it deliberately is not
//!
//! **Not a remote administration tool.** It accepts no arbitrary commands from
//! the network. Everything a phone can ask for goes through
//! `forge_runner::commands`, which is the same gated path the localhost API
//! uses: approvals are answered, not issued; instructions are typed into an
//! agent's own terminal; destructive commands still cannot be cleared from a
//! wrist. A device must be explicitly paired, on your own network, before it can
//! say anything at all — and unpairing revokes it.
//!
//! That boundary is the point. "Control your computer from your phone" is only
//! worth having if it cannot become "control your computer from anyone's phone".
//!
//! # The window is a browser pointed at the local server
//!
//! Not Tauri's asset protocol. That was the first implementation and it did not
//! work: the app fetches `/v1/fleet` **same-origin**, because it is written to be
//! served by the runner. Under `tauri://localhost` those requests resolve against
//! the asset protocol and never reach the embedded axum server, so every screen
//! would read "cannot reach the runner".
//!
//! Loading `http://127.0.0.1:<port>` instead makes the desktop app the same
//! deployment the browser already uses — same origin, same SSE stream, no
//! Tauri-specific code in the client at all. Desktop-only controls are HTTP
//! routes merged onto the same router rather than IPC commands, for the same
//! reason: one path, not two.
//!
//! # Why the PTY backend
//!
//! A desktop app is the process you are looking at. tmux's advantage — panes
//! that outlive the daemon — is worth little here, and requiring it would put an
//! install step in front of the first run on macOS and make Windows impossible.
//! Sessions live and die with the window, which is what a window implies.
//! `--terminal tmux` on the CLI runner is still there for a server.

use std::sync::Arc;

use axum::extract::State;
use axum::routing::{get, post};
use axum::{Json, Router};
use forge_runner::state::{AppState, RelayInfo};
use forge_runner::terminal::AnyTerminal;
use forge_runner::{api, relay, session};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

mod settings;
use settings::Settings;

/// The port the embedded runner prefers.
///
/// The same default the CLI uses, so a phone already paired with
/// `forge-runner serve` on this machine keeps working. Loopback only — anything
/// remote comes through the relay.
const PREFERRED_PORT: u16 = 7842;

/// What the desktop-only screens need. Everything else is the ordinary API.
#[derive(serde::Serialize, Clone)]
struct DesktopStatus {
    machine: String,
    terminal: String,
    /// False here: with the PTY backend, sessions end when this app does.
    sessions_survive_restart: bool,
    relay: Option<String>,
    channel: Option<String>,
    data_directory: String,
    agents: Vec<AgentStatus>,
}

#[derive(serde::Serialize, Clone)]
struct AgentStatus {
    id: String,
    name: String,
    installed: bool,
    supervised: bool,
}

async fn desktop_status(State(state): State<Arc<AppState>>) -> Json<DesktopStatus> {
    Json(DesktopStatus {
        machine: state.machine_id.clone(),
        terminal: state.terminal.name().to_owned(),
        sessions_survive_restart: state.terminal.is_durable(),
        relay: state.relay.as_ref().map(|info| info.url.clone()),
        channel: state.relay.as_ref().map(|info| info.channel.clone()),
        data_directory: Settings::directory().display().to_string(),
        agents: forge_core::agent::AGENTS
            .iter()
            .map(|spec| AgentStatus {
                id: spec.agent.as_str().to_owned(),
                name: spec.display_name.to_owned(),
                installed: spec.binary.is_empty() || forge_runner::pty::binary_exists(spec.binary),
                supervised: spec.is_supervised(),
            })
            .collect(),
    })
}

#[derive(serde::Deserialize)]
struct RelayBody {
    /// `wss://…`, or null to go back to loopback-only.
    url: Option<String>,
}

/// Point this machine at a relay, so a paired device can reach it from anywhere.
///
/// Takes effect on restart. Reconnecting the link live would tear down every
/// paired device's socket mid-approval, and this is a thing you do once.
async fn set_relay(Json(body): Json<RelayBody>) -> Json<serde_json::Value> {
    let mut settings = Settings::load();
    settings.relay = body.url.filter(|url| !url.trim().is_empty());
    match settings.save() {
        Ok(()) => Json(serde_json::json!({
            "relay": settings.relay,
            "restart_required": true,
        })),
        Err(err) => Json(serde_json::json!({ "error": err.to_string() })),
    }
}

/// Routes that only exist in the desktop build, merged onto the runner's own.
///
/// Merged rather than served separately so the window has one origin: an app on
/// a second port would hit CORS and need a second SSE connection for no gain.
fn desktop_routes(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/v1/desktop/status", get(desktop_status))
        .route("/v1/desktop/relay", post(set_relay))
        .with_state(state)
}

fn main() {
    let settings = Settings::load();

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");

    let state = runtime.block_on(build_state(&settings));

    // Bound *before* the window exists, so the page cannot load against a port
    // nothing is listening on yet — and so the URL can name the port we actually
    // got if the preferred one was taken.
    let listener = runtime
        .block_on(bind())
        .expect("could not listen on loopback");
    let addr = listener.local_addr().expect("listener has an address");

    let served = Arc::clone(&state);
    runtime.spawn(async move {
        let app_dir = std::path::PathBuf::from("web/dist");
        let app_dir = app_dir.join("index.html").is_file().then_some(app_dir);
        let router = api::router_with_app(Arc::clone(&served), app_dir)
            .merge(desktop_routes(Arc::clone(&served)));

        if let Err(err) = axum::serve(listener, router).await {
            eprintln!("the local API stopped: {err}");
        }
    });

    println!("RelayForge desktop — serving http://{addr}");
    println!("  data       {}", Settings::directory().display());
    println!(
        "  terminal   {} (sessions end with this app)",
        state.terminal.name()
    );

    tauri::Builder::default()
        .manage(Arc::clone(&state))
        .setup(move |app| {
            // The window is a browser on the embedded server. Same origin as the
            // API, so `/v1/*` and the SSE stream work exactly as they do under
            // `forge-runner serve` — see the module docs.
            let url = format!("http://{addr}")
                .parse()
                .expect("a loopback URL is always valid");

            WebviewWindowBuilder::new(app, "main", WebviewUrl::External(url))
                .title("RelayForge")
                .inner_size(1100.0, 760.0)
                .min_inner_size(380.0, 480.0)
                .build()?;

            build_tray(app.handle())?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("failed to start RelayForge");
}

/// Listen on loopback, preferring the port a paired phone already knows.
///
/// Falls back to an ephemeral port rather than refusing to start: the usual
/// reason 7842 is taken is that a `forge-runner serve` is already running, and
/// "the app will not open" is a worse answer than "it opened on another port".
/// Remote devices reach this machine through the relay, which does not care
/// which local port it is on.
async fn bind() -> std::io::Result<tokio::net::TcpListener> {
    match tokio::net::TcpListener::bind(("127.0.0.1", PREFERRED_PORT)).await {
        Ok(listener) => Ok(listener),
        Err(err) => {
            eprintln!(
                "port {PREFERRED_PORT} is in use ({err}) — is a `forge-runner serve` \
                 already running? Falling back to a free port."
            );
            tokio::net::TcpListener::bind(("127.0.0.1", 0)).await
        }
    }
}

async fn build_state(settings: &Settings) -> Arc<AppState> {
    let store = forge_core::store::SqliteStore::open(settings.database_path())
        .expect("could not open the RelayForge database");

    let identity = Arc::new(
        forge_crypto::keystore::load_or_create(settings.key_path())
            .expect("could not load this machine's key"),
    );

    let relay_info = settings.relay.as_ref().map(|url| RelayInfo {
        url: url.clone(),
        channel: channel_for(&identity),
    });

    // A desktop app is the process you are looking at, so PTYs it owns are the
    // right backend — and the only one available on Windows.
    let terminal = Arc::new(AnyTerminal::Pty(forge_runner::pty::PtyTerminal::new()));

    let state = AppState::build_with_terminal(
        store,
        |store| {
            let client = forge_gateway::dispatch::AnthropicClient::from_env()?;
            Some(forge_gateway::Gateway::new(
                store,
                client,
                forge_gateway::GatewayConfig::default(),
            ))
        },
        Arc::clone(&identity),
        relay_info.clone(),
        Some(Arc::clone(&terminal)),
    );

    if let Some(info) = relay_info {
        relay::spawn(
            Arc::clone(&state),
            identity,
            relay::RelayConfig {
                url: info.url,
                channel: info.channel,
            },
        );
    }

    session::spawn_poller(session::SessionManager::new(
        Arc::clone(&state),
        Arc::clone(&terminal),
    ));

    state
}

/// The relay channel this machine publishes on.
///
/// The rule itself is [`forge_proto::channel_for`]. It used to be written out
/// here and again in `forge-runner`'s binary; both can be pointed at the same
/// `forge.key`, so a drift between them would have published on a channel no
/// paired device listens to, silently.
fn channel_for(identity: &forge_crypto::Identity) -> String {
    forge_proto::channel_for(identity.public_key().as_str())
}

/// The tray icon.
///
/// A supervised agent host is a thing you want running without a window in the
/// way — the whole point is that you walk away from it. Closing the window hides
/// it; quitting is deliberate, from here.
fn build_tray(app: &tauri::AppHandle) -> tauri::Result<()> {
    let show = MenuItem::with_id(app, "show", "Open RelayForge", true, None::<&str>)?;
    let quit = MenuItem::with_id(
        app,
        "quit",
        "Quit — stops every session",
        true,
        None::<&str>,
    )?;
    let menu = Menu::with_items(app, &[&show, &quit])?;

    TrayIconBuilder::new()
        .menu(&menu)
        .tooltip("RelayForge")
        .on_menu_event(|app, event| match event.id.as_ref() {
            "show" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
            // Said plainly in the menu label: with the PTY backend every session
            // is a child of this process.
            "quit" => app.exit(0),
            _ => {}
        })
        .build(app)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_channel_is_derived_from_the_key_and_is_stable() {
        let identity = forge_crypto::Identity::generate();
        assert_eq!(channel_for(&identity), channel_for(&identity));
        assert!(channel_for(&identity).starts_with("forge-"));
    }

    /// The exact channel this key produces.
    ///
    /// `forge-runner`'s binary derives the same string from the same key with
    /// its own copy of this rule, and asserts the same constant. The two must
    /// agree: a desktop app and a CLI runner sharing `forge.key` publish on one
    /// channel, and if they disagree the paired phone hears nothing — no error,
    /// anywhere, just silence.
    ///
    /// Asserting only `starts_with("forge-")`, as the test above does, would let
    /// a change from 16 characters to 12 through.
    #[test]
    fn the_channel_rule_is_the_one_the_runner_uses() {
        let identity = forge_crypto::Identity::from_secret_base64(
            "tapeuo2KzNeIV8FIWkWZ4JtK39yyr83NmVW2pBYYkaU",
        )
        .unwrap();
        assert_eq!(channel_for(&identity), "forge-kFLWAF8DqRIvUm8g");
    }

    #[test]
    fn two_machines_do_not_share_a_channel() {
        // A shared channel would put two runners' ciphertext on one fan-out, and
        // pairing one phone would show it the other machine's traffic.
        assert_ne!(
            channel_for(&forge_crypto::Identity::generate()),
            channel_for(&forge_crypto::Identity::generate())
        );
    }

    #[tokio::test]
    async fn a_taken_port_falls_back_instead_of_refusing_to_start() {
        // The usual reason 7842 is taken is a `forge-runner serve` already
        // running. "The app will not open" is a worse answer than "it opened
        // somewhere else"; remote devices arrive via the relay either way.
        let hog = tokio::net::TcpListener::bind(("127.0.0.1", PREFERRED_PORT)).await;
        let listener = bind().await.expect("should still bind somewhere");
        let port = listener.local_addr().unwrap().port();
        if hog.is_ok() {
            assert_ne!(port, PREFERRED_PORT, "fell back off the taken port");
        }
        assert_ne!(port, 0);
    }

    /// Decoding side of [`DesktopStatus`], which is serialise-only.
    #[derive(serde::Deserialize)]
    struct DesktopStatusEcho {
        terminal: String,
        data_directory: String,
        agents: Vec<AgentEcho>,
    }

    #[derive(serde::Deserialize)]
    struct AgentEcho {
        id: String,
    }

    #[tokio::test]
    async fn the_desktop_routes_answer_on_the_same_origin_as_the_api() {
        // The defect this guards: the window used to load from Tauri's asset
        // protocol, where every same-origin `/v1/*` fetch missed the embedded
        // server entirely and every screen read "cannot reach the runner".
        let state = AppState::build(
            forge_core::store::SqliteStore::open_in_memory().unwrap(),
            |_| None,
            Arc::new(forge_crypto::Identity::generate()),
            None,
        );
        let router = api::router_with_app(Arc::clone(&state), None)
            .merge(desktop_routes(Arc::clone(&state)));

        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let _ = axum::serve(listener, router).await;
        });

        let base = format!("http://{addr}");
        let fleet = reqwest::get(format!("{base}/v1/fleet")).await.unwrap();
        assert!(fleet.status().is_success(), "the ordinary API");

        let status: DesktopStatusEcho = reqwest::get(format!("{base}/v1/desktop/status"))
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(status.terminal, "tmux");
        assert!(!status.data_directory.is_empty());
        assert!(status.agents.iter().any(|agent| agent.id == "claude-code"));
    }
}
