//! Thin binary over [`forge_relay`].

use std::process::ExitCode;

use forge_crypto::token::TokenVerifier;
use forge_relay::webpush::VapidKey;
use forge_relay::{DEFAULT_PORT, DEFAULT_PUSH_SUBJECT, RelayState, router};

/// Ask a running `forge-cloud` for the key it signs with.
///
/// Saves copying a base64 string between two machines, which is the step an
/// operator gets wrong — and getting it wrong means every client is refused with
/// a signature error that looks nothing like "you pasted the key badly".
async fn fetch_auth_key(base_url: &str) -> Result<TokenVerifier, Box<dyn std::error::Error>> {
    let url = format!("{}/v1/auth/public-key", base_url.trim_end_matches('/'));
    let body: serde_json::Value = reqwest::Client::new()
        .get(&url)
        .timeout(std::time::Duration::from_secs(10))
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    let key = body
        .get("key")
        .and_then(|key| key.as_str())
        .ok_or("the control plane did not return a key")?;
    Ok(TokenVerifier::from_public_base64(key)?)
}

const USAGE: &str = "\
forge-relay — RelayForge relay

USAGE:
    forge-relay [--port <port>] [--bind <addr>]
                [--vapid-key <path>] [--push-subject <mailto:…>]
                [--auth-key <base64url> | --auth-from <control-plane-url>]

The relay forwards end-to-end encrypted envelopes between a runner and its
paired devices. It cannot read them. It keeps nothing after a restart.

With --auth-key (or --auth-from, which fetches it from a running forge-cloud at
startup) every connection must present a short-lived token minted by the control
plane, scoped to one channel. Without it the relay behaves as it always has:
knowing a channel id is enough to join. That is fine for one person on their own
network and wrong for anything shared.

The key is the *verifying* half. This process cannot mint a token, so a
compromised relay still cannot grant itself access to a channel.

With --vapid-key it also wakes devices that are not connected, over WebPush.
The wake-up carries no payload: the relay cannot read what triggered it, so it
has nothing truthful to put in a notification. The device wakes, connects, and
decrypts locally.

The key file is created 0600 on first start and reused. Do not delete it —
every subscription a browser made is bound to the public half it saw, so a new
key silently stops waking every device that ever subscribed.

DEFAULTS:
    --port 7843    --bind 0.0.0.0    --push-subject <this project's URL>
";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        print!("{USAGE}");
        return ExitCode::SUCCESS;
    }

    let value_of = |name: &str| {
        args.iter()
            .position(|arg| arg == name)
            .and_then(|index| args.get(index + 1))
            .cloned()
    };
    let port: u16 = value_of("--port")
        .and_then(|raw| raw.parse().ok())
        .unwrap_or(DEFAULT_PORT);
    let bind = value_of("--bind").unwrap_or_else(|| "0.0.0.0".to_owned());
    let vapid_path = value_of("--vapid-key");
    let subject = value_of("--push-subject").unwrap_or_else(|| DEFAULT_PUSH_SUBJECT.to_owned());
    let auth_key = value_of("--auth-key");
    let auth_from = value_of("--auth-from");

    match serve(
        &bind,
        port,
        vapid_path.as_deref(),
        subject,
        auth_key.as_deref(),
        auth_from.as_deref(),
    ) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("error: {err}");
            ExitCode::FAILURE
        }
    }
}

/// Load the VAPID key, minting one on first start.
///
/// Reuses `forge_crypto`'s key-file handling rather than a second, subtly
/// different implementation: created `0600` before anything is written to it,
/// and refused outright if anyone else can read it.
fn load_vapid(path: &str) -> Result<VapidKey, Box<dyn std::error::Error>> {
    if std::path::Path::new(path).exists() {
        return Ok(VapidKey::from_secret_base64url(
            &forge_crypto::keystore::read_secret(path)?,
        )?);
    }
    let key = VapidKey::generate();
    forge_crypto::keystore::write_secret(path, &key.to_secret_base64url())?;
    Ok(key)
}

fn serve(
    bind: &str,
    port: u16,
    vapid_path: Option<&str>,
    subject: String,
    auth_key: Option<&str>,
    auth_from: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    let vapid = match vapid_path {
        Some(path) => Some(load_vapid(path)?),
        None => None,
    };

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;

    // Fetching the key is a startup step, not a per-request one: a relay that
    // asked the control plane on every connection would fail closed the moment
    // that service blinked, which is the opposite of what a relay is for.
    let auth = match (auth_key, auth_from) {
        (Some(key), _) => Some(TokenVerifier::from_public_base64(key)?),
        (None, Some(url)) => Some(runtime.block_on(fetch_auth_key(url))?),
        (None, None) => None,
    };

    runtime.block_on(async {
        let listener = tokio::net::TcpListener::bind((bind, port)).await?;
        let addr = listener.local_addr()?;
        println!("forge-relay listening on {addr}");
        println!("  channel    ws://{addr}/v1/channel/{{channel}}");
        println!("  push       POST http://{addr}/v1/push/{{channel}}");
        println!("  storage    none — envelopes are forwarded, never kept");

        match &vapid {
            Some(key) => {
                println!(
                    "  webpush    on · {} ({})",
                    vapid_path.unwrap_or_default(),
                    subject
                );
                // Printed so it can be pasted into a client that cannot reach
                // `/v1/push/vapid` yet, and so an operator can confirm it did
                // not change across a restart.
                println!("  vapid key  {}", key.public_key_base64url());
            }
            None => println!("  webpush    off (pass --vapid-key <path> to wake sleeping devices)"),
        }

        match &auth {
            Some(verifier) => println!("  auth       on · control-plane key {}", verifier.key_id()),
            None => println!(
                "  auth       OPEN — anyone who knows a channel id may join it. \
                 Pass --auth-key for a shared deployment."
            ),
        }

        let state = match auth {
            Some(verifier) => RelayState::gated(vapid, subject, verifier),
            None => RelayState::with_push(vapid, subject),
        };

        axum::serve(listener, router(state))
            .with_graceful_shutdown(async {
                let _ = tokio::signal::ctrl_c().await;
                println!("\nshutting down");
            })
            .await?;
        Ok(())
    })
}
