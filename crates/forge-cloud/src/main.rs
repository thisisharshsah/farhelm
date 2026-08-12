//! Thin binary over [`forge_cloud`].

use std::process::ExitCode;
use std::sync::Arc;

use forge_cloud::{
    CloudConfig, CloudState, DEFAULT_PORT, api, billing::Billing, store::CloudStore,
};
use forge_crypto::token::TokenSigner;

const USAGE: &str = "\
forge-cloud — RelayForge control plane

USAGE:
    forge-cloud [--port <port>] [--bind <addr>] [--db <path>] [--key <path>]
                [--relay-url <ws-url>] [--public-url <https-url>]
                [--app-dir <path>]

Accounts, organisations, roles, plans, and the runner/device registry. Devices
sign in here and get a short-lived token for a relay channel; runners enrol here
with an enrolment key and appear in the fleet by themselves.

It never sees a session, an approval or a diff — those stay sealed between a
runner and its devices, which is why a compromise here is an access problem and
not a content one.

With --app-dir it also serves the built PWA, so one Cloudflare tunnel to this
process is a complete deployment.

DEFAULTS:
    --port 7844   --bind 127.0.0.1   --db forge-cloud.db   --key forge-cloud.key
    --relay-url ws://127.0.0.1:7843
    --public-url http://127.0.0.1:<port>

ENVIRONMENT (billing is off unless STRIPE_SECRET_KEY is set):
    STRIPE_SECRET_KEY      a restricted or secret key
    STRIPE_WEBHOOK_SECRET  whsec_… — without it every webhook is refused
    STRIPE_PRICE_PRO       the recurring price id for the Pro plan
    STRIPE_PRICE_TEAM      the recurring price id for the Team plan

The signing key is created 0600 on first start and reused. Deleting it signs
everyone out and makes the relay refuse every token until it is reconfigured.
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
    // Loopback by default. This process is expected to sit behind a Cloudflare
    // tunnel, which reaches it over loopback — binding 0.0.0.0 by default would
    // put accounts and billing on the local network for no reason.
    let bind = value_of("--bind").unwrap_or_else(|| "127.0.0.1".to_owned());
    let db = value_of("--db").unwrap_or_else(|| "forge-cloud.db".to_owned());
    let key_path = value_of("--key").unwrap_or_else(|| "forge-cloud.key".to_owned());
    let app_dir = value_of("--app-dir");

    let config = CloudConfig {
        relay_url: value_of("--relay-url").unwrap_or_else(|| "ws://127.0.0.1:7843".to_owned()),
        public_url: value_of("--public-url").unwrap_or_else(|| format!("http://127.0.0.1:{port}")),
    };

    match serve(&bind, port, &db, &key_path, app_dir.as_deref(), config) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("error: {err}");
            ExitCode::FAILURE
        }
    }
}

/// Load the signing key, minting one on first start.
///
/// Reuses `forge_crypto::keystore`, which creates the file `0600` before writing
/// and refuses to read one anybody else can.
fn load_signer(path: &str) -> Result<TokenSigner, Box<dyn std::error::Error>> {
    if std::path::Path::new(path).exists() {
        return Ok(TokenSigner::from_secret_base64(
            &forge_crypto::keystore::read_secret(path)?,
        )?);
    }
    let signer = TokenSigner::generate();
    forge_crypto::keystore::write_secret(path, &signer.to_secret_base64())?;
    Ok(signer)
}

fn serve(
    bind: &str,
    port: u16,
    db: &str,
    key_path: &str,
    app_dir: Option<&str>,
    config: CloudConfig,
) -> Result<(), Box<dyn std::error::Error>> {
    let signer = load_signer(key_path)?;
    let store = CloudStore::open(db)?;
    let billing = Billing::from_env();

    let public_key = signer.verifier().to_public_base64();
    let billing_on = billing.is_enabled();
    let purchasable = billing.purchasable();
    let schema = store.schema_version()?;

    let state = Arc::new(CloudState {
        store,
        signer,
        billing,
        config: config.clone(),
    });

    let mut router = api::router(Arc::clone(&state)).merge(forge_cloud::mcp::router(state));
    if let Some(dir) = app_dir {
        // Unknown paths fall back to index.html so the hash-routed PWA survives
        // a hard refresh. `/v1/*` is matched first and never reaches this.
        let index = std::path::Path::new(dir).join("index.html");
        router = router.fallback_service(
            tower_http::services::ServeDir::new(dir)
                .fallback(tower_http::services::ServeFile::new(index)),
        );
    }

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;

    runtime.block_on(async {
        let listener = tokio::net::TcpListener::bind((bind, port)).await?;
        let addr = listener.local_addr()?;

        println!("forge-cloud listening on {addr}");
        println!("  database   {db} (schema {schema})");
        println!("  public     {}", config.public_url);
        println!("  relay      {}", config.relay_url);
        println!("  app        {}", app_dir.unwrap_or("not served"));
        // Printed so it can be pasted into `forge-relay --auth-key` without a
        // round trip through the API, and so an operator can confirm it did not
        // change across a restart.
        println!("  auth key   {public_key}");
        match billing_on {
            true => println!(
                "  billing    stripe · purchasable: {}",
                purchasable
                    .iter()
                    .map(|plan| plan.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
            false => println!("  billing    off — every workspace is on the Free plan"),
        }

        axum::serve(listener, router)
            .with_graceful_shutdown(async {
                let _ = tokio::signal::ctrl_c().await;
                println!("\nshutting down");
            })
            .await?;
        Ok(())
    })
}
