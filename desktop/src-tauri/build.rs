//! Two jobs: Tauri's own codegen, and making sure the directory it insists on
//! exists before it goes looking for it.

use std::path::{Path, PathBuf};

fn main() {
    ensure_frontend_dist();
    tauri_build::build();
}

/// The file written beside the placeholder to say the placeholder is what it is.
///
/// Without it the runner cannot tell "the web app is built" from "a build
/// script left a note here", and its startup banner would report the app as
/// present. Vite empties `outDir` when it builds, so a real build removes this.
const SENTINEL: &str = ".not-built";

/// Make `frontendDist` exist, because `tauri::generate_context!` panics if it
/// does not.
///
/// That directory is produced by `pnpm --filter @relayforge/web build`, which
/// cargo knows nothing about. So on a clean checkout `cargo build --workspace`,
/// `cargo test --workspace` and `cargo clippy --workspace --all-targets` all
/// failed here — and `check.sh` could not pass at all, because it lints twelve
/// steps before it builds the web app. A Rust build that depends on a
/// JavaScript build with nothing declaring the order is a build that works only
/// for people who happen to run the steps in the right sequence.
///
/// So if the directory is missing, write a placeholder into it. The placeholder
/// is not a stub to satisfy a check: it is the page saying the web app has not
/// been built yet, which is what the runner now serves at `/` instead of the
/// bare empty 404 it used to.
///
/// An existing directory is never touched — this only ever creates what is not
/// there, and never overwrites a real build.
fn ensure_frontend_dist() {
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let Some(dist) = frontend_dist(&manifest) else {
        // No `frontendDist` configured, or the config could not be read. Say so
        // and let `tauri_build` produce the real error — guessing a path here
        // would create a directory nothing is looking for.
        println!("cargo:warning=could not read frontendDist from tauri.conf.json");
        return;
    };

    if dist.join("index.html").is_file() {
        return;
    }

    if let Err(err) = std::fs::create_dir_all(&dist) {
        println!("cargo:warning=could not create {}: {err}", dist.display());
        return;
    }
    let _ = std::fs::write(dist.join(SENTINEL), "");
    if let Err(err) = std::fs::write(dist.join("index.html"), PLACEHOLDER) {
        println!("cargo:warning=could not write placeholder: {err}");
    }
}

/// Resolve `build.frontendDist` against the crate root, the way Tauri does.
fn frontend_dist(manifest: &Path) -> Option<PathBuf> {
    let text = std::fs::read_to_string(manifest.join("tauri.conf.json")).ok()?;
    let config: serde_json::Value = serde_json::from_str(&text).ok()?;
    let relative = config.get("build")?.get("frontendDist")?.as_str()?;
    Some(manifest.join(relative))
}

/// What you get at `/` when the web app has not been built.
///
/// Self-contained by necessity — it is served by a runner that has no assets,
/// to a browser that may be offline. It states the one command that fixes it.
const PLACEHOLDER: &str = r#"<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>RelayForge — web app not built</title>
<style>
  :root { color-scheme: light dark; }
  body {
    font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    max-width: 34rem; margin: 12vh auto; padding: 0 1.5rem;
    background: #fff; color: #14191d;
  }
  @media (prefers-color-scheme: dark) { body { background: #0f1316; color: #e4e9eb; } }
  h1 { font-size: 1.35rem; letter-spacing: -0.01em; margin: 0 0 0.75rem; }
  p { margin: 0 0 1rem; }
  code, pre { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.9em; }
  pre {
    padding: 0.85rem 1rem; overflow-x: auto; border-radius: 2px;
    background: #f2f5f6; border: 1px solid #d9e0e3;
  }
  @media (prefers-color-scheme: dark) {
    pre { background: #171c20; border-color: #262d33; }
  }
  .muted { color: #6e7d87; font-size: 0.92rem; }
</style>
</head>
<body>
  <h1>The web app has not been built</h1>
  <p>The runner is up — its API is answering on <code>/v1</code>. What is missing
     is the built front end it serves at this address.</p>
  <pre>pnpm install
pnpm --filter @relayforge/web build</pre>
  <p>Then restart the runner. If the app is built somewhere else, point at it
     with <code>--app-dir &lt;path&gt;</code>.</p>
  <p class="muted">This page is a placeholder written by the desktop crate's
     build script. A real build replaces it.</p>
</body>
</html>
"#;
