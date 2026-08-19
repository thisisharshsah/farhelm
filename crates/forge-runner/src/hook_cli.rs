//! `forge-runner hook` — the process Claude Code spawns per hook event.
//!
//! Reads the event on stdin, asks the running daemon what to do, writes the
//! reply on stdout. All the policy lives in the daemon; this is a courier.
//!
//! Every failure path here ends in exit 0 with a permissive-to-Claude-Code
//! answer (`defer`), never exit 2 — see [`crate::hook`] for why.

use std::io::Read;
use std::time::Duration;

use crate::hook::{self, Decision, HookEvent, RequestKind};

/// Where the daemon listens. Overridable so a second runner on another port
/// can be driven by its own hook registration.
fn runner_url() -> String {
    std::env::var("FORGE_RUNNER_URL").unwrap_or_else(|_| "http://127.0.0.1:7842".to_owned())
}

/// Ceiling on the whole round trip. Slightly above the daemon's own approval
/// wait so the daemon, which can record a proper `timeout` decision, is the one
/// that decides — this only fires if the daemon itself wedges.
fn client_timeout() -> Duration {
    Duration::from_secs(16 * 60)
}

/// Read stdin, act, print the reply. Always `Ok` in practice: an error here
/// would block an agent.
pub async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut raw = String::new();
    std::io::stdin().read_to_string(&mut raw)?;

    let reply = match hook::parse(&raw) {
        Ok(event) => handle(event).await,
        Err(err) => {
            // Unparseable input is our problem, not the agent's. Say so on
            // stderr (visible in `claude --debug`) and get out of the way.
            eprintln!("forge-runner hook: could not parse event: {err}");
            hook::acknowledge()
        }
    };

    println!("{reply}");
    Ok(())
}

async fn handle(event: HookEvent) -> serde_json::Value {
    let client = match reqwest::Client::builder().timeout(client_timeout()).build() {
        Ok(client) => client,
        Err(err) => {
            eprintln!("forge-runner hook: could not build http client: {err}");
            return hook::acknowledge();
        }
    };
    let base = runner_url();

    match event {
        HookEvent::ToolRequest {
            kind,
            session_id,
            cwd,
            tool_name,
            payload,
            ..
        } => {
            tool_request(
                &client,
                &base,
                kind,
                &session_id,
                &cwd,
                &tool_name,
                &payload,
            )
            .await
        }

        HookEvent::Stopped {
            session_id,
            cwd,
            last_message,
        } => {
            post_notice(
                &client,
                &format!("{base}/v1/hooks/stop"),
                &session_id,
                &cwd,
                &last_message,
                None,
            )
            .await;
            hook::acknowledge()
        }

        HookEvent::Notified {
            session_id,
            cwd,
            notification_type,
            message,
        } => {
            post_notice(
                &client,
                &format!("{base}/v1/hooks/notification"),
                &session_id,
                &cwd,
                &message,
                Some(&notification_type),
            )
            .await;
            hook::acknowledge()
        }

        HookEvent::Ignored { .. } => hook::acknowledge(),
    }
}

#[derive(serde::Deserialize)]
struct ToolRequestReply {
    decision: String,
    reason: String,
}

async fn tool_request(
    client: &reqwest::Client,
    base: &str,
    kind: RequestKind,
    session_id: &str,
    cwd: &str,
    tool_name: &str,
    payload: &str,
) -> serde_json::Value {
    let response = client
        .post(format!("{base}/v1/hooks/tool-request"))
        .json(&serde_json::json!({
            "agent_session_id": session_id,
            "cwd": cwd,
            "tool": tool_name,
            "payload": payload,
        }))
        .send()
        .await;

    let reply = match response {
        Ok(response) if response.status().is_success() => response.json::<ToolRequestReply>().await,
        Ok(response) => {
            let status = response.status();
            eprintln!("forge-runner hook: runner returned {status}");
            return hook::decision_json(
                kind,
                Decision::Defer,
                &format!("RelayForge returned {status} — falling back to the normal prompt"),
            );
        }
        Err(err) => {
            // The daemon is down or unreachable. Degrade to plain Claude Code
            // rather than to an unsupervised agent.
            eprintln!("forge-runner hook: runner unreachable: {err}");
            return hook::decision_json(
                kind,
                Decision::Defer,
                "RelayForge is unreachable — falling back to the normal prompt",
            );
        }
    };

    match reply {
        Ok(reply) => {
            let decision = match reply.decision.as_str() {
                "approved" => Decision::Allow,
                // Both an explicit deny and a timeout block the call. They read
                // differently to the developer, which is what `reason` is for.
                _ => Decision::Deny,
            };
            hook::decision_json(kind, decision, &reply.reason)
        }
        Err(err) => {
            eprintln!("forge-runner hook: could not read decision: {err}");
            hook::decision_json(
                kind,
                Decision::Defer,
                "RelayForge sent an unreadable decision — falling back to the normal prompt",
            )
        }
    }
}

async fn post_notice(
    client: &reqwest::Client,
    url: &str,
    session_id: &str,
    cwd: &str,
    message: &str,
    notification_type: Option<&str>,
) {
    let body = serde_json::json!({
        "agent_session_id": session_id,
        "cwd": cwd,
        "message": message,
        "notification_type": notification_type,
    });
    // Best effort: a lost Stop notice costs a stale status in the fleet view,
    // which is not worth blocking the agent over.
    if let Err(err) = client.post(url).json(&body).send().await {
        eprintln!("forge-runner hook: could not report to runner: {err}");
    }
}

/// The settings block a user pastes into `.claude/settings.json`.
pub fn settings_snippet(binary: &str) -> String {
    let hooks = serde_json::json!({
        "hooks": {
            "PreToolUse": [{
                "matcher": "*",
                "hooks": [{ "type": "command", "command": format!("{binary} hook") }]
            }],
            "Stop": [{
                "hooks": [{ "type": "command", "command": format!("{binary} hook") }]
            }],
            "Notification": [{
                "hooks": [{ "type": "command", "command": format!("{binary} hook") }]
            }]
        }
    });
    serde_json::to_string_pretty(&hooks).unwrap_or_default()
}

/// The hook block, as a value rather than as text.
pub fn hook_block(binary: &str) -> serde_json::Value {
    serde_json::json!({
        "PreToolUse": [{
            "matcher": "*",
            "hooks": [{ "type": "command", "command": format!("{binary} hook") }]
        }],
        "Stop": [{
            "hooks": [{ "type": "command", "command": format!("{binary} hook") }]
        }],
        "Notification": [{
            "hooks": [{ "type": "command", "command": format!("{binary} hook") }]
        }]
    })
}

/// What happened when hooks were written into a settings file.
#[derive(Debug, PartialEq, Eq)]
pub enum Installed {
    /// The file did not exist and was created.
    Created,
    /// An existing file gained the hooks, keeping everything else it had.
    Merged,
    /// The hooks were already there and pointed at this same binary.
    AlreadyCurrent,
    /// Hooks were there but pointed somewhere else; they now point here.
    Replaced,
}

/// Merge RelayForge's hooks into a Claude Code settings file.
///
/// Printing a block for somebody to paste was the original design, and it is a
/// step that has to be repeated per repository and can be done wrong in silence
/// — a stray comma, or pasting into the object above the one you meant. This
/// writes it.
///
/// **Merging, never replacing the file.** A settings file usually has other
/// things in it — permissions, a model choice, environment — and losing those
/// would be a far worse outcome than a hook that has to be pasted. Only the
/// `hooks` key is touched.
///
/// Idempotent: running it twice leaves one copy, and re-running after the
/// binary moves repoints it rather than accumulating a second entry.
pub fn install_into(path: &std::path::Path, binary: &str) -> std::io::Result<Installed> {
    let existing = match std::fs::read_to_string(path) {
        Ok(text) => Some(text),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => None,
        Err(err) => return Err(err),
    };

    let wanted = hook_block(binary);

    let (mut settings, outcome) = match &existing {
        None => (serde_json::json!({}), Installed::Created),
        Some(text) if text.trim().is_empty() => (serde_json::json!({}), Installed::Created),
        Some(text) => {
            let parsed: serde_json::Value = serde_json::from_str(text).map_err(|err| {
                // A settings file that is not JSON must not be overwritten:
                // whatever is in it is somebody's, and this cannot merge into
                // something it cannot read.
                std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    format!(
                        "{} is not valid JSON ({err}) — fix or move it first",
                        path.display()
                    ),
                )
            })?;
            let outcome = match parsed.get("hooks") {
                Some(hooks) if *hooks == wanted => Installed::AlreadyCurrent,
                Some(_) => Installed::Replaced,
                None => Installed::Merged,
            };
            (parsed, outcome)
        }
    };

    if outcome == Installed::AlreadyCurrent {
        return Ok(outcome);
    }

    match settings.as_object_mut() {
        Some(map) => {
            map.insert("hooks".into(), wanted);
        }
        None => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("{} is JSON but not an object", path.display()),
            ));
        }
    }

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut rendered = serde_json::to_string_pretty(&settings)?;
    rendered.push('\n');
    std::fs::write(path, rendered)?;
    Ok(outcome)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "forge-hooks-{name}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.join(".claude").join("settings.json")
    }

    fn read(path: &std::path::Path) -> serde_json::Value {
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    #[test]
    fn installing_into_nothing_creates_the_file() {
        let path = temp("create");
        assert_eq!(install_into(&path, "/bin/fr").unwrap(), Installed::Created);
        assert_eq!(
            read(&path)["hooks"]["PreToolUse"][0]["hooks"][0]["command"],
            "/bin/fr hook"
        );
    }

    #[test]
    fn installing_keeps_everything_else_in_the_file() {
        // The property that makes writing safe rather than reckless: a settings
        // file usually holds permissions and a model choice, and losing those
        // would be worse than pasting a block by hand.
        let path = temp("merge");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(
            &path,
            r#"{"model":"opus","permissions":{"allow":["Bash(ls:*)"]}}"#,
        )
        .unwrap();

        assert_eq!(install_into(&path, "/bin/fr").unwrap(), Installed::Merged);

        let after = read(&path);
        assert_eq!(after["model"], "opus");
        assert_eq!(after["permissions"]["allow"][0], "Bash(ls:*)");
        assert!(after["hooks"]["Stop"].is_array());
    }

    #[test]
    fn installing_twice_changes_nothing_the_second_time() {
        let path = temp("idempotent");
        install_into(&path, "/bin/fr").unwrap();
        let first = std::fs::read_to_string(&path).unwrap();

        assert_eq!(
            install_into(&path, "/bin/fr").unwrap(),
            Installed::AlreadyCurrent
        );
        assert_eq!(std::fs::read_to_string(&path).unwrap(), first);
    }

    #[test]
    fn a_moved_binary_is_repointed_rather_than_duplicated() {
        let path = temp("repoint");
        install_into(&path, "/old/fr").unwrap();
        assert_eq!(install_into(&path, "/new/fr").unwrap(), Installed::Replaced);

        let after = read(&path);
        assert_eq!(
            after["hooks"]["PreToolUse"][0]["hooks"][0]["command"],
            "/new/fr hook"
        );
        assert_eq!(
            after["hooks"]["PreToolUse"].as_array().unwrap().len(),
            1,
            "a second run must not stack a second entry"
        );
    }

    #[test]
    fn a_settings_file_that_is_not_json_is_refused_rather_than_overwritten() {
        let path = temp("garbage");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "{ not json").unwrap();

        assert!(install_into(&path, "/bin/fr").is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "{ not json");
    }

    #[test]
    fn the_settings_snippet_registers_all_three_events() {
        let snippet = settings_snippet("/usr/local/bin/forge-runner");
        let parsed: serde_json::Value = serde_json::from_str(&snippet).unwrap();

        for event in ["PreToolUse", "Stop", "Notification"] {
            assert!(
                parsed["hooks"][event].is_array(),
                "{event} missing from the snippet"
            );
        }
        assert_eq!(
            parsed["hooks"]["PreToolUse"][0]["hooks"][0]["command"],
            "/usr/local/bin/forge-runner hook"
        );
    }

    #[test]
    fn the_runner_url_is_overridable_but_defaults_to_loopback() {
        // Read without mutating the environment: the default must be loopback,
        // because the runner never listens anywhere else.
        assert!(runner_url().starts_with("http://127.0.0.1:"));
    }

    #[test]
    fn the_client_timeout_outlives_the_daemons_own_wait() {
        // The daemon waits 15 minutes and then records a `timeout` decision. If
        // this fired first, that record would never be written.
        assert!(client_timeout() > Duration::from_secs(15 * 60));
    }
}
