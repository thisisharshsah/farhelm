//! Shared runner state: the store handle, the live-output buffers, and the
//! event bus every connected client tails.
//!
//! Output is deliberately *not* in SQLite. It is a throttled tail for glancing
//! at, not an audit record — §6 sends `output_chunk` over the wire and forgets
//! it. Keeping it in memory means a chatty agent can't grow the database.

use forge_sqlite::SqliteStore;
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};

use forge_app::store::prelude::*;
use forge_gateway::{AnthropicClient, Gateway};
use tokio::sync::broadcast;

/// Where this runner is reachable, once a relay is configured.
#[derive(Debug, Clone)]
pub struct RelayInfo {
    pub url: String,
    pub channel: String,
}

/// The gateway as the runner holds it: the real store, the real provider.
///
/// `Option` because the runner must start and serve the read-only API with no
/// API key configured — a fresh clone should show you the UI before it asks for
/// a credential.
pub type RunnerGateway = Gateway<Arc<SqliteStore>, AnthropicClient>;

/// Lines retained per session. A phone showing more than this would need to
/// scroll past what a glance can use anyway.
const OUTPUT_TAIL_CAPACITY: usize = 200;

/// Lines kept on disk per session.
///
/// Larger than the live tail because this is the part you scroll back through:
/// the instruction that started the work should still be there when the work
/// finishes. Bounded because a transcript nobody trims is a disk that fills up
/// while nobody is looking.
const OUTPUT_HISTORY_CAPACITY: usize = 5_000;

/// How many lines between trims of the stored transcript.
const PRUNE_EVERY: u32 = 500;

/// Resolve this runner's machine row, creating it on first start.
///
/// The id is derived from the hostname rather than random, so restarting the
/// runner — or reopening the same database from a rebuilt binary — re-attaches
/// to the existing machine instead of orphaning its repos.
fn ensure_machine(store: &SqliteStore) -> String {
    let name = machine_name();
    let id = format!("machine-{name}");
    let now = forge_app::time::now_ms();

    let created_at = store
        .get_machine(&id)
        .ok()
        .flatten()
        .map(|machine| machine.created_at)
        .unwrap_or(now);

    // A failure here is not fatal: the read-only API still works, and the hook
    // bridge will report the real error when it tries to use the machine.
    let _ = store.upsert_machine(&forge_proto::types::Machine {
        id: cloned(&id),
        name,
        // Filled in by device pairing (M3). Empty until then rather than fake.
        pubkey: String::new(),
        last_seen_at: Some(now),
        created_at,
    });
    id
}

fn cloned(value: &str) -> String {
    value.to_owned()
}

fn machine_name() -> String {
    if let Ok(name) = std::env::var("FORGE_MACHINE_NAME")
        && !name.trim().is_empty()
    {
        return name.trim().to_owned();
    }
    std::process::Command::new("hostname")
        .output()
        .ok()
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|name| name.trim().to_owned())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "runner".to_owned())
}

/// How many events a slow client may fall behind before it is dropped and told
/// to re-fetch. Bounded so one stalled phone cannot pin memory.
const EVENT_BUFFER: usize = 256;

/// The event contract and the output line moved to `forge-proto`: four client
/// implementations parse them, and they had no business living in the same
/// module as the runner's in-memory buffers. Re-exported so `state::ServerEvent`
/// keeps resolving for the modules that publish them.
pub use forge_proto::events::ServerEvent;
pub use forge_proto::views::OutputLine;

struct OutputBuffer {
    next_seq: u64,
    lines: VecDeque<OutputLine>,
}

impl Default for OutputBuffer {
    fn default() -> Self {
        Self {
            next_seq: 0,
            lines: VecDeque::with_capacity(OUTPUT_TAIL_CAPACITY),
        }
    }
}

pub struct AppState {
    pub store: Arc<SqliteStore>,
    /// This runner's long-term keypair. Devices encrypt to its public half.
    pub identity: Arc<forge_crypto::Identity>,
    /// Outstanding pairing codes. In memory only — an unredeemed code should not
    /// survive a restart.
    pub pairing: Mutex<forge_crypto::PairingBroker>,
    /// The relay channel this runner publishes on, if a relay is configured.
    pub relay: Option<RelayInfo>,
    /// This runner's machine row. Hook callbacks resolve their `cwd` to a repo
    /// on this machine, so it has to exist before the first callback lands.
    pub machine_id: String,
    pub gateway: Option<RunnerGateway>,
    pub events: broadcast::Sender<ServerEvent>,
    /// Questions the terminal watcher has already raised, so a prompt sitting on
    /// screen across several polls produces one approval rather than one per
    /// poll. See [`crate::watcher`].
    pub seen_prompts: crate::watcher::SeenPrompts,
    /// Local additions to the destructive-command rules (D3). Empty by default;
    /// the built-ins stand on their own.
    pub policy: forge_domain::risk::Policy,
    /// The terminal backend. One instance, because the PTY backend owns its
    /// panes — `TmuxTerminal` is stateless only because tmux holds the state.
    pub terminal: Arc<crate::terminal::AnyTerminal>,
    /// Native agent tasks drafting right now.
    ///
    /// In memory rather than counted from the database, because that is what it
    /// describes: a spawned loop, which does not survive a restart. The rows
    /// left behind by one are reconciled at startup — see
    /// [`crate::task::reconcile_after_restart`].
    pub running_tasks: std::sync::atomic::AtomicUsize,
    output: Mutex<HashMap<String, OutputBuffer>>,
    /// Lines written since each session's transcript was last trimmed.
    since_prune: Mutex<HashMap<String, u32>>,
    /// Last pane snapshot per session, for [`AppState::new_output_lines`].
    snapshots: Mutex<HashMap<String, Vec<String>>>,
}

impl AppState {
    /// Build state with a throwaway identity and no relay. Tests only — the
    /// daemon loads a persistent key so paired devices survive a restart.
    ///
    /// The closure lets the caller construct a gateway over the same store
    /// handle, keeping the `Arc` in one place rather than making the caller
    /// re-wrap it.
    #[cfg(test)]
    pub fn with_gateway(
        store: SqliteStore,
        build: impl FnOnce(Arc<SqliteStore>) -> Option<RunnerGateway>,
    ) -> Arc<Self> {
        Self::build(
            store,
            build,
            Arc::new(forge_crypto::Identity::generate()),
            None,
        )
    }

    /// The common case: tmux panes, built-in destructive-command rules.
    pub fn build(
        store: SqliteStore,
        build: impl FnOnce(Arc<SqliteStore>) -> Option<RunnerGateway>,
        identity: Arc<forge_crypto::Identity>,
        relay: Option<RelayInfo>,
    ) -> Arc<Self> {
        Self::assemble(
            store,
            build,
            identity,
            relay,
            None,
            forge_domain::risk::Policy::default(),
        )
    }

    /// [`AppState::build`] with the terminal backend chosen explicitly.
    ///
    /// `None` means tmux, which is what every existing caller wants and what a
    /// server should use — panes that survive a runner restart.
    pub fn build_with_terminal(
        store: SqliteStore,
        build: impl FnOnce(Arc<SqliteStore>) -> Option<RunnerGateway>,
        identity: Arc<forge_crypto::Identity>,
        relay: Option<RelayInfo>,
        terminal: Option<Arc<crate::terminal::AnyTerminal>>,
    ) -> Arc<Self> {
        Self::assemble(
            store,
            build,
            identity,
            relay,
            terminal,
            forge_domain::risk::Policy::default(),
        )
    }

    /// [`AppState::build_with_terminal`] plus local destructive-command rules.
    pub fn build_with_policy(
        store: SqliteStore,
        build: impl FnOnce(Arc<SqliteStore>) -> Option<RunnerGateway>,
        identity: Arc<forge_crypto::Identity>,
        relay: Option<RelayInfo>,
        terminal: Option<Arc<crate::terminal::AnyTerminal>>,
        policy: forge_domain::risk::Policy,
    ) -> Arc<Self> {
        Self::assemble(store, build, identity, relay, terminal, policy)
    }

    /// The one place an `AppState` is actually constructed.
    ///
    /// The three `build_*` functions above are argument defaults over this. They
    /// used to be a chain, and the longest link in it built an `Arc`, tore it
    /// back apart with `Arc::try_unwrap(...).unwrap_or_else(|_| unreachable!())`
    /// to assign a single field, and re-wrapped it. That worked only because no
    /// clone existed yet — a fact nothing enforced. Anyone adding a
    /// `let handle = Arc::clone(&state)` to the constructor it delegated to
    /// would have turned a runner start-up into a panic, and the compiler would
    /// have had nothing to say about it.
    fn assemble(
        store: SqliteStore,
        build: impl FnOnce(Arc<SqliteStore>) -> Option<RunnerGateway>,
        identity: Arc<forge_crypto::Identity>,
        relay: Option<RelayInfo>,
        terminal: Option<Arc<crate::terminal::AnyTerminal>>,
        policy: forge_domain::risk::Policy,
    ) -> Arc<Self> {
        let (events, _) = broadcast::channel(EVENT_BUFFER);
        let machine_id = ensure_machine(&store);
        let store = Arc::new(store);
        Arc::new(Self {
            gateway: build(Arc::clone(&store)),
            store,
            identity,
            pairing: Mutex::new(forge_crypto::PairingBroker::new()),
            relay,
            machine_id,
            events,
            seen_prompts: crate::watcher::SeenPrompts::default(),
            policy,
            terminal: terminal.unwrap_or_else(|| {
                Arc::new(crate::terminal::AnyTerminal::Tmux(
                    crate::terminal::TmuxTerminal::default(),
                ))
            }),
            running_tasks: std::sync::atomic::AtomicUsize::new(0),
            output: Mutex::new(HashMap::new()),
            since_prune: Mutex::new(HashMap::new()),
            snapshots: Mutex::new(HashMap::new()),
        })
    }

    /// Publish an event. A send with no subscribers is not an error — the
    /// runner keeps working whether or not a phone is watching.
    pub fn publish(&self, event: ServerEvent) {
        let _ = self.events.send(event);
    }

    /// Append a line to a session's tail and broadcast it.
    pub fn push_output(&self, session_id: &str, text: impl Into<String>, at_ms: i64) {
        let line = {
            let mut buffers = self.output.lock().expect("output buffers poisoned");
            let buffer = buffers.entry(session_id.to_owned()).or_default();
            let line = OutputLine {
                seq: buffer.next_seq,
                text: text.into(),
                at_ms,
            };
            buffer.next_seq += 1;
            if buffer.lines.len() == OUTPUT_TAIL_CAPACITY {
                buffer.lines.pop_front();
            }
            buffer.lines.push_back(line.clone());
            line
        };

        // Written through to the store so the transcript survives a restart.
        // The ring buffer above is still the live tail — reading the last few
        // lines of a running session must not touch the disk — and this is the
        // record behind it.
        //
        // A failure here is logged rather than propagated: losing a line of
        // history is bad, and refusing to show the user the line that is
        // already on their screen would be worse.
        if let Err(err) = self
            .store
            .append_output(session_id, std::slice::from_ref(&line))
        {
            eprintln!("session {session_id}: output not recorded: {err}");
        }
        self.note_output_written(session_id);

        self.publish(ServerEvent::OutputChunk {
            session_id: session_id.to_owned(),
            line,
        });
    }

    /// Trim a session's stored transcript now and then.
    ///
    /// Every `PRUNE_EVERY` lines rather than on every one: the delete is a
    /// scan, and paying for it once per line would make a chatty build pay for
    /// tidiness it does not need yet.
    fn note_output_written(&self, session_id: &str) {
        let due = {
            let mut counts = self.since_prune.lock().expect("prune counter poisoned");
            let count = counts.entry(session_id.to_owned()).or_insert(0);
            *count += 1;
            if *count >= PRUNE_EVERY {
                *count = 0;
                true
            } else {
                false
            }
        };
        if due && let Err(err) = self.store.prune_output(session_id, OUTPUT_HISTORY_CAPACITY) {
            eprintln!("session {session_id}: transcript not pruned: {err}");
        }
    }

    /// Which lines of a pane snapshot have not been sent yet.
    ///
    /// `tmux capture-pane` returns the *visible pane*, not a stream, so polling
    /// it naively would re-send every line on every tick. This diffs against the
    /// previous snapshot by finding the longest overlap between the old tail and
    /// the new head — which is exactly what a scrolled pane looks like — and
    /// returns only what is genuinely new.
    pub fn new_output_lines(&self, session_id: &str, snapshot: &str) -> Vec<String> {
        // tmux pads the pane to its full height; those blanks are not output.
        let fresh: Vec<String> = snapshot
            .lines()
            .map(str::to_owned)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .skip_while(|line| line.trim().is_empty())
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();

        let mut snapshots = self.snapshots.lock().expect("snapshots poisoned");
        let previous = snapshots.get(session_id).cloned().unwrap_or_default();

        // Longest suffix of the old snapshot that is a prefix of the new one.
        let overlap = (1..=previous.len().min(fresh.len()))
            .rev()
            .find(|&k| previous[previous.len() - k..] == fresh[..k])
            .unwrap_or(0);

        // That suffix rule assumes a terminal that *scrolls*: new output arrives
        // at the bottom and everything above keeps its place. A full-screen TUI
        // does not work that way. Claude Code repaints the whole pane — banner,
        // tips, a spinner glyph that changes every frame — so two consecutive
        // snapshots overlap almost nowhere, the rule concludes that everything
        // is new, and the entire screen is emitted again. Poll after poll, the
        // transcript becomes the same banner a hundred times over with a
        // different spinner character each time, and the actual answer is
        // somewhere inside it.
        //
        // A repaint is recognisable: no overlap at all, yet most of what is on
        // screen was on screen a moment ago. In that case the only honest
        // "new output" is the lines that were not there before.
        //
        // Scrolling is untouched — it has an overlap, so it never reaches here —
        // and that matters, because agents without a hook system are read
        // through this pane and dropping a line would drop a question somebody
        // is waiting on.
        let new_lines = if overlap == 0 && is_repaint(&previous, &fresh) {
            fresh
                .iter()
                .filter(|line| !previous.contains(line))
                .cloned()
                .collect()
        } else {
            fresh[overlap..].to_vec()
        };

        snapshots.insert(session_id.to_owned(), fresh);
        new_lines
    }

    /// The most recent `limit` lines, oldest first.
    pub fn output_tail(&self, session_id: &str, limit: usize) -> Vec<OutputLine> {
        {
            let buffers = self.output.lock().expect("output buffers poisoned");
            if let Some(buffer) = buffers.get(session_id) {
                return buffer
                    .lines
                    .iter()
                    .skip(buffer.lines.len().saturating_sub(limit))
                    .cloned()
                    .collect();
            }
        }

        // Nothing in memory. Either this session predates the current process —
        // a restart, which used to mean the transcript was simply gone — or it
        // has produced nothing yet. The store knows which.
        //
        // Deliberately not repopulating the ring buffer: that is the live tail
        // of a running session, and filling it from history would make a
        // finished session look like it is still producing output.
        self.store
            .output_tail(session_id, limit)
            .unwrap_or_else(|err| {
                eprintln!("session {session_id}: transcript unreadable: {err}");
                Vec::new()
            })
    }
}

/// Whether two snapshots are the same screen redrawn rather than a scroll.
///
/// Judged by how much of the new screen was already on the old one. A repaint
/// changes a spinner and maybe a line or two; a scroll moves everything up, so
/// even where the suffix rule misses, most lines are still shared. The
/// The threshold is three fifths rather than something stricter: a frame that
/// advances a spinner *and* adds a couple of lines still shares only about
/// two thirds of its screen, and demanding more than that lets the whole banner
/// through again. It stays a majority, because treating a scroll as a repaint
/// would drop real output and that is the more expensive mistake — though a
/// scroll almost never arrives here at all, since it has an overlap.
fn is_repaint(previous: &[String], fresh: &[String]) -> bool {
    let interesting: Vec<&String> = fresh
        .iter()
        .filter(|line| !line.trim().is_empty())
        .collect();
    if interesting.len() < 4 || previous.is_empty() {
        return false;
    }
    let shared = interesting
        .iter()
        .filter(|line| previous.contains(**line))
        .count();
    shared * 5 >= interesting.len() * 3
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state() -> Arc<AppState> {
        AppState::with_gateway(SqliteStore::open_in_memory().unwrap(), |_| None)
    }

    #[test]
    fn a_transcript_outlives_the_process_that_wrote_it() {
        // The failure this prevents, and the reason any of this exists: the
        // tail lived in memory, so a deploy, a crash or a closed laptop emptied
        // every session's transcript and the screen you steer from came back
        // blank.
        //
        // A file-backed store opened twice *is* the restart. An in-memory one
        // would not do: it dies with its connection, so it could not tell a
        // transcript that persisted from one that never left the process.
        let path = std::env::temp_dir().join(format!(
            "forge-transcript-{}-{:?}.db",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_file(&path);

        {
            let before = AppState::with_gateway(SqliteStore::open(&path).unwrap(), |_| None);
            before.push_output("s1", "\u{203a} fix the failing test", 10);
            before.push_output("s1", "running cargo test\u{2026}", 11);
            assert_eq!(before.output_tail("s1", 10).len(), 2);
        }

        let after = AppState::with_gateway(SqliteStore::open(&path).unwrap(), |_| None);
        let tail = after.output_tail("s1", 10);

        assert_eq!(tail.len(), 2, "the transcript did not survive the restart");
        assert_eq!(tail[0].text, "\u{203a} fix the failing test");
        assert_eq!(tail[1].text, "running cargo test\u{2026}");

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_session_nobody_has_written_to_still_reads_empty() {
        let state = state();
        assert!(state.output_tail("never-seen", 10).is_empty());
    }

    /// A full-screen TUI: a fixed banner, and one line that changes per frame.
    fn frame(spinner: &str, body: &[&str]) -> String {
        let mut screen = vec![
            "╭─── Claude Code v2.1.235 ───╮".to_string(),
            "│ Tips for getting started   │".to_string(),
            "│ Welcome back!              │".to_string(),
            "╰────────────────────────────╯".to_string(),
            format!("{spinner} thinking"),
        ];
        screen.extend(body.iter().map(|line| line.to_string()));
        screen.join("\n")
    }

    #[test]
    fn a_repainting_tui_does_not_re_emit_its_whole_screen() {
        // The failure this prevents, and it is what the transcript actually
        // looked like: Claude Code repaints its entire pane every frame, the
        // suffix rule found no overlap, and the banner plus the tips box plus
        // the spinner went into the transcript again on every poll — a hundred
        // copies of the same screen with a different spinner glyph, the answer
        // buried somewhere inside.
        let state = state();

        let first = state.new_output_lines("s1", &frame("✢", &["Reading entitlements.rs"]));
        assert!(first.len() > 4, "the first frame is all new: {first:?}");

        // Same screen, spinner advanced, one line of genuinely new content.
        let second = state.new_output_lines(
            "s1",
            &frame("✳", &["Reading entitlements.rs", "There are two rungs"]),
        );

        assert!(
            !second.iter().any(|line| line.contains("Welcome back")),
            "the banner was emitted again: {second:?}"
        );
        assert!(
            second.iter().any(|line| line.contains("two rungs")),
            "the new line was lost: {second:?}"
        );
        assert!(
            second.len() <= 2,
            "a repaint should yield the changed lines only, got {second:?}"
        );
    }

    #[test]
    fn the_screen_that_prompted_this_stops_repeating() {
        // Taken from a real transcript: Claude Code's banner, the Fable notice,
        // the prompt, and an answer being written a word at a time. Before the
        // repaint rule this produced the banner once per poll, which is what
        // the session view actually looked like.
        let state = state();
        let banner = [
            "╭─── Claude Code v2.1.235 ───╮",
            "│ Tips for getting started   │",
            "│ Welcome back!              │",
            "╰────────────────────────────╯",
            "▎ Fable 5 is now a standard part of your Max plan",
            "❯ what's our suggested upgrade",
        ];
        let screen = |spinner: &str, answer: &str| {
            let mut lines: Vec<String> = banner.iter().map(|l| l.to_string()).collect();
            lines.push(format!("{spinner} Cogitated for 1m 15s"));
            lines.push(answer.to_string());
            lines.join("\n")
        };

        state.new_output_lines("s1", &screen("✢", "There isn't one global"));
        let mut emitted = Vec::new();
        for (spinner, answer) in [
            ("✳", "There isn't one global"),
            ("✶", "There isn't one global \"suggested upgrade\""),
            (
                "✻",
                "There isn't one global \"suggested upgrade\" — the ladder",
            ),
        ] {
            emitted.extend(state.new_output_lines("s1", &screen(spinner, answer)));
        }

        let banners = emitted
            .iter()
            .filter(|line| line.contains("Welcome back"))
            .count();
        assert_eq!(banners, 0, "the banner repeated: {emitted:?}");
        assert!(
            emitted.iter().any(|line| line.contains("the ladder")),
            "the answer never arrived: {emitted:?}"
        );
    }

    #[test]
    fn a_scrolling_log_still_reports_every_line() {
        // The property that must not be traded away for the one above. Agents
        // without a hook system are read through this pane, so a dropped line
        // is a question somebody is waiting on that never arrives.
        let state = state();
        state.new_output_lines("s1", "one\ntwo\nthree");

        let next = state.new_output_lines("s1", "two\nthree\nfour\nfive");
        assert_eq!(next, vec!["four".to_string(), "five".to_string()]);
    }

    #[test]
    fn a_repeated_line_in_a_scrolling_log_is_not_swallowed() {
        // Content-based de-duplication only applies to a repaint. A build that
        // legitimately prints the same line twice must still show it twice.
        let state = state();
        state.new_output_lines("s1", "compiling\nok");
        let next = state.new_output_lines("s1", "compiling\nok\ncompiling\nok");
        assert_eq!(next, vec!["compiling".to_string(), "ok".to_string()]);
    }

    #[test]
    fn an_unchanged_screen_reports_nothing_new() {
        // The suffix rule already covers this and must keep covering it: a
        // poll that finds the pane exactly as it left it has nothing to say.
        let state = state();
        state.new_output_lines("s1", "$ ls\nfile.txt");
        assert!(state.new_output_lines("s1", "$ ls\nfile.txt").is_empty());
    }

    #[test]
    fn a_short_screen_is_never_judged_a_repaint() {
        // Two or three recurring lines are not evidence of a TUI. Below the
        // size floor the content rule is not consulted at all, so a quiet
        // agent that reprints a short prompt is still reported.
        assert!(!is_repaint(
            &["$ ls".to_string(), "file.txt".to_string()],
            &["$ ls".to_string(), "file.txt".to_string()]
        ));
    }

    #[test]
    fn sequence_numbers_are_monotonic_per_session() {
        let state = state();
        state.push_output("s1", "one", 0);
        state.push_output("s2", "other session", 0);
        state.push_output("s1", "two", 1);

        let tail = state.output_tail("s1", 10);
        assert_eq!(tail.iter().map(|l| l.seq).collect::<Vec<_>>(), vec![0, 1]);
        assert_eq!(state.output_tail("s2", 10)[0].seq, 0);
    }

    #[test]
    fn the_tail_is_bounded_and_keeps_the_newest_lines() {
        let state = state();
        for i in 0..(OUTPUT_TAIL_CAPACITY + 50) {
            state.push_output("s1", format!("line {i}"), i as i64);
        }

        let tail = state.output_tail("s1", usize::MAX);
        assert_eq!(tail.len(), OUTPUT_TAIL_CAPACITY);
        assert_eq!(
            tail.last().unwrap().text,
            format!("line {}", OUTPUT_TAIL_CAPACITY + 49)
        );
        // Sequence numbers keep counting past the eviction point, so a client
        // can tell that lines were dropped rather than silently missing them.
        assert_eq!(tail[0].seq, 50);
    }

    #[test]
    fn an_unknown_session_has_an_empty_tail_rather_than_erroring() {
        assert!(state().output_tail("never-seen", 10).is_empty());
    }

    #[test]
    fn output_reaches_a_subscriber() {
        let state = state();
        let mut rx = state.events.subscribe();
        state.push_output("s1", "hello", 7);

        match rx.try_recv().unwrap() {
            ServerEvent::OutputChunk { session_id, line } => {
                assert_eq!(session_id, "s1");
                assert_eq!(line.text, "hello");
                assert_eq!(line.at_ms, 7);
            }
            other => panic!("expected output chunk, got {other:?}"),
        }
    }

    #[test]
    fn a_repeated_snapshot_produces_no_new_lines() {
        let state = state();
        assert_eq!(
            state.new_output_lines("s1", "one\ntwo\n"),
            vec!["one", "two"]
        );
        assert!(state.new_output_lines("s1", "one\ntwo\n").is_empty());
    }

    #[test]
    fn appended_lines_are_the_only_ones_returned() {
        let state = state();
        state.new_output_lines("s1", "one\ntwo\n");
        assert_eq!(
            state.new_output_lines("s1", "one\ntwo\nthree\n"),
            vec!["three"]
        );
    }

    #[test]
    fn a_scrolled_pane_does_not_resend_what_is_still_visible() {
        let state = state();
        state.new_output_lines("s1", "one\ntwo\nthree\n");
        // The pane scrolled: `one` fell off the top, `four` appeared.
        assert_eq!(
            state.new_output_lines("s1", "two\nthree\nfour\n"),
            vec!["four"]
        );
    }

    #[test]
    fn a_cleared_pane_sends_everything_again() {
        let state = state();
        state.new_output_lines("s1", "one\ntwo\n");
        // No overlap at all — the agent ran `clear`.
        assert_eq!(state.new_output_lines("s1", "fresh\n"), vec!["fresh"]);
    }

    #[test]
    fn tmux_padding_is_not_mistaken_for_output() {
        let state = state();
        assert_eq!(state.new_output_lines("s1", "one\n\n\n\n"), vec!["one"]);
        // The padding grew; still nothing new happened.
        assert!(state.new_output_lines("s1", "one\n\n\n\n\n\n").is_empty());
    }

    #[test]
    fn blank_lines_inside_output_are_preserved() {
        let state = state();
        assert_eq!(
            state.new_output_lines("s1", "one\n\ntwo\n"),
            vec!["one", "", "two"]
        );
    }

    #[test]
    fn publishing_with_nobody_listening_is_fine() {
        let state = state();
        state.publish(ServerEvent::SessionUpsert {
            session_id: "s1".into(),
        });
    }
}
