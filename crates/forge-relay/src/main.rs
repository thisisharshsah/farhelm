//! Thin binary over [`forge_relay`].

use std::process::ExitCode;

use forge_relay::webpush::VapidKey;
use forge_relay::{DEFAULT_PORT, DEFAULT_PUSH_SUBJECT, RelayState, router};

const USAGE: &str = "\
forge-relay — RelayForge relay

USAGE:
    forge-relay [--port <port>] [--bind <addr>]
                [--vapid-key <path>] [--push-subject <mailto:…>]

The relay forwards end-to-end encrypted envelopes between a runner and its
paired devices. It cannot read them. It keeps nothing after a restart.

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

    match serve(&bind, port, vapid_path.as_deref(), subject) {
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
) -> Result<(), Box<dyn std::error::Error>> {
    let vapid = match vapid_path {
        Some(path) => Some(load_vapid(path)?),
        None => None,
    };

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;

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

        axum::serve(listener, router(RelayState::with_push(vapid, subject)))
            .with_graceful_shutdown(async {
                let _ = tokio::signal::ctrl_c().await;
                println!("\nshutting down");
            })
            .await?;
        Ok(())
    })
}
