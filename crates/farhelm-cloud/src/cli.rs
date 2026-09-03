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

`doctor` says what is actually in this deployment — workspaces, machines and\nwhether anything can reach them — by reading the database directly, so it\nstill answers when the service will not start.\n\nAccounts, organisations, roles, plans, and the runner/device registry. Devices
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

/// `farhelm cloud doctor` — what is actually in this deployment.
///
/// Written the day an outage was diagnosed by opening two SQLite files by hand
/// and reading a request log. Everything below is a check that investigation
/// needed, so that the next one is a command.
///
/// It reads the database directly rather than asking the API. The operator is
/// on the box; requiring the service to be healthy in order to ask what is
/// wrong with it gets the dependency exactly backwards, and the most useful
/// moment for this is when the control plane will not start.
fn doctor(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    let value_of = |name: &str| {
        args.iter()
            .position(|arg| arg == name)
            .and_then(|index| args.get(index + 1))
            .cloned()
    };
    let db = defaulted(value_of("--db"), "farhelm-cloud.db", "forge-cloud.db");
    let key_path = defaulted(value_of("--key"), "farhelm-cloud.key", "forge-cloud.key");

    let good = |label: &str, detail: &str| println!("  \u{2713} {label:<13} {detail}");
    let bad = |label: &str, detail: &str| println!("  \u{2717} {label:<13} {detail}");
    let note = |label: &str, detail: &str| println!("  \u{b7} {label:<13} {detail}");
    let fix = |command: &str| println!("                  fix: {command}");

    println!();

    if !std::path::Path::new(&db).exists() {
        bad("database", &format!("{db} does not exist"));
        println!();
        println!("  A control plane started here would create an empty one — no accounts,");
        println!("  no workspaces, and every machine told its enrolment key is invalid.");
        println!("  If this deployment has data, it is under another path or another name.");
        println!();
        return Ok(());
    }

    let store = CloudStore::open(&db)?;
    good(
        "database",
        &format!("{db} (schema {})", store.schema_version()?),
    );

    match std::path::Path::new(&key_path).exists() {
        true => good("signing key", &key_path),
        false => {
            bad("signing key", &format!("{key_path} is missing"));
            fix("it is minted on first start — but a *new* one signs everyone out");
        }
    }

    let now = farhelm_app::time::now_ms();
    let orgs = store.orgs()?;
    if orgs.is_empty() {
        note(
            "workspaces",
            "none — nobody has signed up on this deployment",
        );
        println!();
        return Ok(());
    }

    let mut problems = 0usize;
    for org in &orgs {
        println!();
        println!("  \u{1b}[1m{}\u{1b}[0m  ({})", org.name, org.id);

        let members = store.members(&org.id)?.len();
        let runners = store.runners(&org.id)?;
        let devices = store.devices(&org.id)?;

        note("  members", &members.to_string());

        if runners.is_empty() {
            problems += 1;
            bad(
                "  machines",
                "none enrolled — there is nothing to supervise",
            );
            fix("run the install one-liner on the machine you want supervised");
        }

        for runner in &runners {
            let online = runner.is_online(now);
            let age = (now - runner.last_seen_at) / 1000;
            let detail = match online {
                true => format!("online \u{b7} v{}", runner.version),
                false => format!("offline \u{b7} last seen {}", human_age(age)),
            };
            if online {
                good(&format!("  {}", runner.name), &detail);
            } else {
                problems += 1;
                bad(&format!("  {}", runner.name), &detail);
                fix("check the daemon is running on that machine: farhelm doctor");
            }

            if runner.pending_public_key.is_some() {
                problems += 1;
                bad("    identity", "changed, and nobody has confirmed it");
                println!("                  Every device is refused until someone approves it in");
                println!(
                    "                  the app. This is what a reinstalled machine looks like."
                );
            }
        }

        // The check that would have answered the whole investigation in one
        // line: machines that nothing can reach are not a working deployment,
        // however healthy each machine reports itself to be.
        if devices.is_empty() && !runners.is_empty() {
            problems += 1;
            bad(
                "  devices",
                "none registered — nothing can reach these machines",
            );
            fix("open the app and sign in on the phone or browser you want to use");
        } else if !devices.is_empty() {
            good("  devices", &format!("{} registered", devices.len()));
        }
    }

    println!();
    match problems {
        0 => println!("  \u{2713} nothing to fix."),
        1 => println!("  1 problem above."),
        n => println!("  {n} problems above."),
    }
    println!();
    Ok(())
}

/// "3 minutes", "2 days" — enough to tell "just now" from "since Tuesday".
fn human_age(seconds: i64) -> String {
    match seconds {
        s if s < 90 => format!("{s}s ago"),
        s if s < 5400 => format!("{} minutes ago", s / 60),
        s if s < 172_800 => format!("{} hours ago", s / 3600),
        s => format!("{} days ago", s / 86_400),
    }
}

/// Run the control plane from `farhelm cloud`'s arguments.
pub fn run(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        print!("{USAGE}");
        return Ok(());
    }

    if args.first().map(String::as_str) == Some("doctor") {
        return doctor(&args[1..]);
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

    let mut router = api::router(Arc::clone(&state)).merge(crate::mcp::router(Arc::clone(&state)));
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
        // Watch the fleet for machines going quiet. Started inside the runtime
        // because it is a task, and after the state exists because it reads it.
        crate::watch::spawn(Arc::clone(&state));

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

#[cfg(test)]
mod doctor_tests {
    use super::*;

    #[test]
    fn an_age_reads_as_a_person_would_say_it() {
        // The distinction that matters is "just now" versus "since Tuesday" —
        // a raw epoch or a seconds count makes the reader do that arithmetic at
        // the moment they are least inclined to.
        assert_eq!(human_age(12), "12s ago");
        assert_eq!(human_age(600), "10 minutes ago");
        assert_eq!(human_age(7200), "2 hours ago");
        assert_eq!(human_age(345_600), "4 days ago");
    }

    #[test]
    fn the_boundaries_do_not_produce_a_zero() {
        // "0 minutes ago" and "0 hours ago" are what an off-by-one at a
        // boundary looks like, and they read as broken rather than as recent.
        for seconds in [89, 90, 5399, 5400, 172_799, 172_800] {
            let said = human_age(seconds);
            assert!(
                !said.starts_with('0'),
                "{seconds}s rendered as {said}, which reads as a bug"
            );
        }
    }
}
