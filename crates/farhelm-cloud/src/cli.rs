//! `farhelm cloud` — the control-plane half of the single command.
//!
//! Was a binary of its own; see the note in `farhelm_relay::cli` for why it
//! is a subcommand now.

use std::sync::Arc;

use crate::{CloudConfig, CloudState, DEFAULT_PORT, api, billing::Billing, store::CloudStore};
use farhelm_crypto::token::TokenSigner;

pub const USAGE: &str = "\
farhelm cloud — accounts, workspaces and the fleet registry

USAGE:
    farhelm cloud [--port <port>] [--bind <addr>] [--db <path>] [--key <path>]
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
    --port 7844   --bind 127.0.0.1   --db farhelm-cloud.db   --key farhelm-cloud.key
    (the `forge-` names these had before the rename are still read when the
     current ones are absent, and say so once when used)
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

/// An explicit path is taken at face value; an unqualified default resolves
/// through [`farhelm_app::legacy`], so a deployment that predates the rename
/// keeps opening the database it already has.
fn defaulted(flag: Option<String>, new: &str, old: &str) -> String {
    match flag {
        Some(path) => path,
        None => farhelm_app::legacy::state_path(new, old)
            .to_string_lossy()
            .into_owned(),
    }
}

/// Run the control plane from `farhelm cloud`'s arguments.
pub fn run(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        print!("{USAGE}");
        return Ok(());
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
    // Through `legacy`, not a bare default. These two files are every account,
    // workspace and enrolment key in the deployment, and SQLite creates a
    // missing database rather than complaining — so a renamed default does not
    // fail, it comes up *empty*, and the first thing anybody notices is their
    // own machines being told their enrolment key is not valid.
    //
    // That is not hypothetical: it is what the rename did to the deployment
    // this was written on, because the path was passed explicitly in a service
    // definition where no fallback could reach it.
    let db = defaulted(value_of("--db"), "farhelm-cloud.db", "forge-cloud.db");
    let key_path = defaulted(value_of("--key"), "farhelm-cloud.key", "forge-cloud.key");
    let app_dir = value_of("--app-dir");

    let config = CloudConfig {
        relay_url: value_of("--relay-url").unwrap_or_else(|| "ws://127.0.0.1:7843".to_owned()),
        public_url: value_of("--public-url").unwrap_or_else(|| format!("http://127.0.0.1:{port}")),
    };

    serve(&bind, port, &db, &key_path, app_dir.as_deref(), config)
}

/// Load the signing key, minting one on first start.
///
/// Reuses `farhelm_crypto::keystore`, which creates the file `0600` before writing
/// and refuses to read one anybody else can.
fn load_signer(path: &str) -> Result<TokenSigner, Box<dyn std::error::Error>> {
    if std::path::Path::new(path).exists() {
        return Ok(TokenSigner::from_secret_base64(
            &farhelm_crypto::keystore::read_secret(path)?,
        )?);
    }
    let signer = TokenSigner::generate();
    farhelm_crypto::keystore::write_secret(path, &signer.to_secret_base64())?;
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

    let mut router = api::router(Arc::clone(&state)).merge(crate::mcp::router(state));
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

        println!("farhelm cloud listening on {addr}");
        println!("  database   {db} (schema {schema})");
        println!("  public     {}", config.public_url);
        println!("  relay      {}", config.relay_url);
        println!("  app        {}", app_dir.unwrap_or("not served"));
        // Printed so it can be pasted into `farhelm relay --auth-key` without a
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A directory holding whichever of the two names the test is about.
    fn dir(tag: &str, files: &[&str]) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("farhelm-cloud-cli-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        for name in files {
            std::fs::write(dir.join(name), b"x").unwrap();
        }
        dir
    }

    #[test]
    fn a_control_plane_that_predates_the_rename_opens_its_own_database() {
        // The failure this pins is not a missing file — it is a *created* one.
        // SQLite makes a database that is not there, so pointing the control
        // plane at the post-rename name on a deployment that has the old one
        // does not error: it comes up with no accounts, no workspaces and no
        // enrolment keys, and the first symptom is every machine in the fleet
        // being told its own key is invalid.
        let dir = dir("legacy", &["forge-cloud.db", "forge-cloud.key"]);
        let db = dir.join("farhelm-cloud.db");
        let old_db = dir.join("forge-cloud.db");

        assert_eq!(
            defaulted(None, db.to_str().unwrap(), old_db.to_str().unwrap()),
            old_db.to_string_lossy(),
            "an upgrade must not silently start on an empty control plane"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn an_explicit_path_is_still_taken_at_face_value() {
        // Whatever a service definition names, it gets. Searching elsewhere
        // after somebody wrote a path down is its own kind of surprise.
        let dir = dir("explicit", &["forge-cloud.db"]);
        let named = dir.join("somewhere-else.db");
        assert_eq!(
            defaulted(
                Some(named.to_string_lossy().into_owned()),
                dir.join("farhelm-cloud.db").to_str().unwrap(),
                dir.join("forge-cloud.db").to_str().unwrap(),
            ),
            named.to_string_lossy(),
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_fresh_deployment_gets_the_current_name() {
        let dir = dir("fresh", &[]);
        let db = dir.join("farhelm-cloud.db");
        assert_eq!(
            defaulted(
                None,
                db.to_str().unwrap(),
                dir.join("forge-cloud.db").to_str().unwrap()
            ),
            db.to_string_lossy(),
        );
        std::fs::remove_dir_all(&dir).ok();
    }
}
