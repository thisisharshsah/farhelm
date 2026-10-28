//! The Farhelm engine: the local model server the runner owns.
//!
//! Farhelm does the routing, accounting and policy; the arithmetic of running a
//! model (Metal and CUDA kernels, quantized formats, chat templates, tool-call
//! parsers) comes from a pinned llama.cpp server build. The runner installs
//! that build after checking its published SHA-256, starts it on a loopback
//! port, restarts it when it dies, and stops it when the runner stops. Nobody
//! installs Ollama or another model server by hand.
//!
//! It is a separate process rather than a library linked into the runner on
//! purpose: a GPU out-of-memory or a crash in the server takes down the engine,
//! not the approvals and sessions, and restarting the runner (which happens
//! often) does not by itself have to reload eighteen gigabytes of weights.
//!
//! The gateway reaches the engine like any `openai_compatible` provider in the
//! model registry (`FARHELM_MODELS_CONFIG`), so every request still goes
//! through the gateway's policy and ledger. See ADR 0009.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::Deserialize;
use tokio::sync::watch;

/// The llama.cpp build this runner installs and expects.
///
/// Pinned, never "latest": a model's tool-call parsing and chat template live
/// in the server, so a new build is a new deployment and goes through the
/// conformance probe before it is pinned here.
pub const PINNED_BUILD: &str = "b11624";

/// One downloadable archive of [`PINNED_BUILD`], with the SHA-256 GitHub
/// publishes for it.
pub struct PinnedArchive {
    pub asset: &'static str,
    pub sha256: &'static str,
}

/// The archive for the platform this binary was built for, if one is pinned.
///
/// Only Apple Silicon is pinned so far; it is the machine the build was
/// probed on. Other platforms get a clear refusal rather than a guess.
pub fn pinned_archive() -> Option<PinnedArchive> {
    if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        Some(PinnedArchive {
            asset: "llama-b11624-bin-macos-arm64.tar.gz",
            sha256: "5bd8555c20e5d6d45831c038f484769245e5bcc1c265c4911c6ae15e4d9a35df",
        })
    } else {
        None
    }
}

pub fn archive_url(asset: &str) -> String {
    format!("https://github.com/ggml-org/llama.cpp/releases/download/{PINNED_BUILD}/{asset}")
}

pub const DEFAULT_ENGINE_CONFIG: &str = "engine.toml";
/// The first model's port; later models take the next free ones.
pub const DEFAULT_PORT: u16 = 7846;

/// `engine.toml`: the server build and the models it serves.
///
/// Written by `farhelm engine install`, `add-model` and `add-adapter`. Each
/// model gets its own server process and port, so one crashing or running out
/// of memory does not take the others down.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EngineConfig {
    /// The llama.cpp build `server` came from.
    pub build: String,
    /// The `llama-server` binary.
    pub server: PathBuf,
    #[serde(default)]
    pub models: Vec<ModelEntry>,
}

/// One base model and the adapters loaded with it.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelEntry {
    /// The model name the server answers to, and the `model` the registry
    /// sends.
    pub alias: String,
    /// A GGUF file.
    pub model: PathBuf,
    /// Its SHA-256 at install time: the deployment record, not re-hashed on
    /// every start (that is half a minute of disk reads for a 30B model).
    pub model_sha256: String,
    /// Its size at install time, checked on every start instead.
    pub model_bytes: u64,
    pub port: u16,
    #[serde(default = "default_ctx_size")]
    pub ctx_size: u32,
    /// Requests decoded at once. Each one takes its share of `ctx_size`.
    #[serde(default = "default_parallel")]
    pub parallel: u32,
    /// LoRA adapters, loaded switched off. Their position is the id a
    /// registry specialist names (`adapters = [{ id = 0, scale = 1.0 }]`).
    #[serde(default)]
    pub adapters: Vec<AdapterEntry>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AdapterEntry {
    pub name: String,
    /// A GGUF LoRA adapter (`farhelm engine import-adapter` writes one).
    pub path: PathBuf,
    pub sha256: String,
}

/// One model's server: what the supervisor starts.
#[derive(Debug, Clone, PartialEq)]
pub struct ModelServer {
    pub build: String,
    pub server: PathBuf,
    pub model: ModelEntry,
}

fn default_ctx_size() -> u32 {
    32_768
}
fn default_parallel() -> u32 {
    1
}

#[derive(Debug)]
pub struct EngineError(pub String);

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for EngineError {}

fn fail(message: impl Into<String>) -> EngineError {
    EngineError(message.into())
}

fn valid_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

impl EngineConfig {
    /// `Ok(None)` when there is no file: the engine is simply not set up.
    pub fn load(path: &Path) -> Result<Option<Self>, EngineError> {
        let text = match std::fs::read_to_string(path) {
            Ok(text) => text,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(err) => return Err(fail(format!("{}: {err}", path.display()))),
        };
        let config: Self =
            toml::from_str(&text).map_err(|err| fail(format!("{}: {err}", path.display())))?;
        config.validate()?;
        Ok(Some(config))
    }

    pub fn validate(&self) -> Result<(), EngineError> {
        let mut aliases = std::collections::BTreeSet::new();
        let mut ports = std::collections::BTreeSet::new();
        for model in &self.models {
            if !valid_name(&model.alias) {
                return Err(fail(format!(
                    "model alias `{}` must be ASCII letters, digits, '-', '_' or '.'",
                    model.alias
                )));
            }
            if !aliases.insert(model.alias.as_str()) || !ports.insert(model.port) {
                return Err(fail(format!(
                    "model `{}` repeats another model's alias or port",
                    model.alias
                )));
            }
            if model.port == 0
                || model.ctx_size < 2_048
                || model.parallel == 0
                || model.parallel > 16
            {
                return Err(fail(format!(
                    "model `{}` needs a port, ctx_size of at least 2048 and parallel 1 to 16",
                    model.alias
                )));
            }
            let mut names = std::collections::BTreeSet::new();
            for adapter in &model.adapters {
                if !valid_name(&adapter.name) || !names.insert(adapter.name.as_str()) {
                    return Err(fail(format!(
                        "adapter names on `{}` must be distinct and ASCII letters, digits, '-', '_' or '.'",
                        model.alias
                    )));
                }
            }
        }
        Ok(())
    }

    pub fn servers(&self) -> Vec<ModelServer> {
        self.models
            .iter()
            .map(|model| ModelServer {
                build: self.build.clone(),
                server: self.server.clone(),
                model: model.clone(),
            })
            .collect()
    }

    /// The first port from [`DEFAULT_PORT`] up that no model uses.
    pub fn next_port(&self) -> u16 {
        (DEFAULT_PORT..u16::MAX)
            .find(|port| self.models.iter().all(|model| model.port != *port))
            .unwrap_or(DEFAULT_PORT)
    }

    /// Add or replace the model with this alias. A replaced model keeps its
    /// port and adapters unless the new entry names its own.
    pub fn upsert_model(&mut self, mut entry: ModelEntry) {
        match self
            .models
            .iter_mut()
            .find(|model| model.alias == entry.alias)
        {
            Some(existing) => {
                if entry.adapters.is_empty() {
                    entry.adapters = std::mem::take(&mut existing.adapters);
                }
                *existing = entry;
            }
            None => self.models.push(entry),
        }
    }

    /// The `engine.toml` text for this configuration.
    pub fn to_toml(&self) -> String {
        let mut out = format!(
            "# Written by `farhelm engine`. The runner starts one server per model\n\
             # when it starts; the model registry reaches each at its port.\n\
             build = {}\n\
             server = {}\n",
            quote(&self.build),
            quote(&self.server.to_string_lossy()),
        );
        for model in &self.models {
            out.push_str(&format!(
                "\n[[models]]\n\
                 alias = {}\n\
                 model = {}\n\
                 model_sha256 = {}\n\
                 model_bytes = {}\n\
                 port = {}\n\
                 ctx_size = {}\n\
                 parallel = {}\n",
                quote(&model.alias),
                quote(&model.model.to_string_lossy()),
                quote(&model.model_sha256),
                model.model_bytes,
                model.port,
                model.ctx_size,
                model.parallel,
            ));
            for (id, adapter) in model.adapters.iter().enumerate() {
                out.push_str(&format!(
                    "\n# adapter id {id}\n\
                     [[models.adapters]]\n\
                     name = {}\n\
                     path = {}\n\
                     sha256 = {}\n",
                    quote(&adapter.name),
                    quote(&adapter.path.to_string_lossy()),
                    quote(&adapter.sha256),
                ));
            }
        }
        out
    }
}

impl ModelServer {
    /// Check what can go stale between starts: the binary still exists, the
    /// model file is the one that was installed (by size), and the adapters
    /// are still there.
    pub fn preflight(&self) -> Result<(), EngineError> {
        if !self.server.is_file() {
            return Err(fail(format!(
                "the engine server {} is missing; run `farhelm engine install`",
                self.server.display()
            )));
        }
        let path = &self.model.model;
        let bytes = std::fs::metadata(path)
            .map_err(|err| fail(format!("the model {}: {err}", path.display())))?
            .len();
        if bytes != self.model.model_bytes {
            return Err(fail(format!(
                "the model {} is {bytes} bytes, but {} were installed; reinstall it",
                path.display(),
                self.model.model_bytes
            )));
        }
        for adapter in &self.model.adapters {
            if !adapter.path.is_file() {
                return Err(fail(format!(
                    "the adapter {} is missing; import it again",
                    adapter.path.display()
                )));
            }
        }
        Ok(())
    }

    /// The server's arguments. Loopback only, `--jinja` so the model's own
    /// chat template (and with it, tool calling) is used, and every adapter
    /// loaded switched off: a request without a `lora` field gets the base
    /// model, and only a specialist's request switches its adapter on.
    pub fn args(&self) -> Vec<String> {
        let model = &self.model;
        let mut args = vec![
            "--model".into(),
            model.model.to_string_lossy().into_owned(),
            "--alias".into(),
            model.alias.clone(),
            "--host".into(),
            "127.0.0.1".into(),
            "--port".into(),
            model.port.to_string(),
            "--jinja".into(),
            "--ctx-size".into(),
            model.ctx_size.to_string(),
            "--parallel".into(),
            model.parallel.to_string(),
            "--n-gpu-layers".into(),
            "999".into(),
        ];
        for adapter in &model.adapters {
            args.push("--lora".into());
            args.push(adapter.path.to_string_lossy().into_owned());
        }
        if !model.adapters.is_empty() {
            args.push("--lora-init-without-apply".into());
        }
        args
    }

    pub fn base_url(&self) -> String {
        format!("http://127.0.0.1:{}/v1", self.model.port)
    }
}

/// A TOML basic string.
fn quote(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for c in value.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if c.is_control() => out.push_str(&format!("\\u{:04X}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// SHA-256 of a file, streamed: model files do not fit in memory twice.
pub fn sha256_file(path: &Path) -> std::io::Result<String> {
    use sha2::{Digest as _, Sha256};
    use std::io::Read as _;
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 8 * 1024 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

/// Whether a file starts with the GGUF magic.
pub fn is_gguf(path: &Path) -> bool {
    use std::io::Read as _;
    let mut magic = [0u8; 4];
    std::fs::File::open(path)
        .and_then(|mut file| file.read_exact(&mut magic))
        .is_ok()
        && &magic == b"GGUF"
}

/// Find `llama-server` in an unpacked archive. Release archives have moved it
/// between layouts (`build/bin/`, `llama-<build>/`), so it is searched for.
pub fn find_server(root: &Path) -> Option<PathBuf> {
    let name = if cfg!(windows) {
        "llama-server.exe"
    } else {
        "llama-server"
    };
    let mut pending = vec![(root.to_path_buf(), 0usize)];
    while let Some((dir, depth)) = pending.pop() {
        let entries = std::fs::read_dir(&dir).ok()?;
        for entry in entries.flatten() {
            let path = entry.path();
            let kind = entry.file_type().ok()?;
            if kind.is_file() && entry.file_name() == name {
                return Some(path);
            }
            if kind.is_dir() && depth < 3 {
                pending.push((path, depth + 1));
            }
        }
    }
    None
}

/// What the engine is doing, for the banner, `farhelm engine status` and the
/// API.
#[derive(Debug, Clone, PartialEq)]
pub enum EngineState {
    Starting,
    Ready,
    /// It exited or never became healthy; the next attempt is scheduled.
    Restarting {
        attempt: u32,
        reason: String,
    },
    /// A problem a restart cannot fix: a missing binary, a changed model.
    Stopped {
        reason: String,
    },
}

impl std::fmt::Display for EngineState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Starting => f.write_str("starting"),
            Self::Ready => f.write_str("ready"),
            Self::Restarting { attempt, reason } => {
                write!(f, "restarting (attempt {attempt}): {reason}")
            }
            Self::Stopped { reason } => write!(f, "stopped: {reason}"),
        }
    }
}

/// How long to wait before restart `attempt` (1-based): 2 s doubling to a
/// minute. A server that crashes on start must not be relaunched in a loop
/// that pins a core and fills the log.
pub fn backoff(attempt: u32) -> Duration {
    let seconds = 2u64.saturating_mul(1u64 << attempt.saturating_sub(1).min(5));
    Duration::from_secs(seconds.min(60))
}

/// A load can take a while: weights are read from disk and mapped on the GPU.
const READY_DEADLINE: Duration = Duration::from_secs(300);
/// A server that stayed up this long has earned a fresh backoff.
const STABLE_AFTER: Duration = Duration::from_secs(300);
/// The engine log is cut when a start finds it larger than this.
const LOG_LIMIT_BYTES: u64 = 16 * 1024 * 1024;

/// The running supervisor: one task per model server. Dropping it does not
/// stop the servers; call [`Engine::shutdown`].
pub struct Engine {
    pub config: EngineConfig,
    servers: Vec<Supervised>,
    stop: watch::Sender<bool>,
}

struct Supervised {
    server: ModelServer,
    state: Arc<Mutex<EngineState>>,
    task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl Engine {
    /// Start supervising every model. `home` holds the pid files and logs.
    pub fn spawn(config: EngineConfig, home: PathBuf) -> Arc<Self> {
        // The first, single-model engine kept its pid here. A runner upgraded
        // from it may have left that server running on the first port.
        stop_leftover(&home.join("engine.pid"), &config.server);
        let (stop, _) = watch::channel(false);
        let servers = config
            .servers()
            .into_iter()
            .map(|server| {
                let state = Arc::new(Mutex::new(EngineState::Starting));
                let task = tokio::spawn(supervise(
                    server.clone(),
                    home.clone(),
                    Arc::clone(&state),
                    stop.subscribe(),
                ));
                Supervised {
                    server,
                    state,
                    task: Mutex::new(Some(task)),
                }
            })
            .collect();
        Arc::new(Self {
            config,
            servers,
            stop,
        })
    }

    /// Each model server and what it is doing, in configuration order.
    pub fn states(&self) -> Vec<(ModelServer, EngineState)> {
        self.servers
            .iter()
            .map(|supervised| {
                let state = supervised
                    .state
                    .lock()
                    .map(|state| state.clone())
                    .unwrap_or(EngineState::Stopped {
                        reason: "supervisor state poisoned".into(),
                    });
                (supervised.server.clone(), state)
            })
            .collect()
    }

    /// Stop every server and wait for the supervisors to finish.
    pub async fn shutdown(&self) {
        let _ = self.stop.send(true);
        for supervised in &self.servers {
            let task = supervised.task.lock().ok().and_then(|mut task| task.take());
            if let Some(task) = task {
                let _ = task.await;
            }
        }
    }
}

fn set(state: &Mutex<EngineState>, next: EngineState) {
    if let Ok(mut state) = state.lock() {
        *state = next;
    }
}

async fn supervise(
    config: ModelServer,
    home: PathBuf,
    state: Arc<Mutex<EngineState>>,
    mut stopped: watch::Receiver<bool>,
) {
    let alias = config.model.alias.clone();
    let pid_file = home.join(format!("engine-{alias}.pid"));
    let log_file = home.join("logs").join(format!("engine-{alias}.log"));
    stop_leftover(&pid_file, &config.server);

    let mut attempt = 0u32;
    loop {
        if *stopped.borrow() {
            break;
        }
        if let Err(err) = config.preflight() {
            set(&state, EngineState::Stopped { reason: err.0 });
            break;
        }

        let started = Instant::now();
        let reason = match run_once(&config, &pid_file, &log_file, &state, &mut stopped).await {
            Ok(()) => break,
            Err(reason) => reason,
        };
        let _ = std::fs::remove_file(&pid_file);

        attempt = if started.elapsed() >= STABLE_AFTER {
            1
        } else {
            attempt + 1
        };
        set(
            &state,
            EngineState::Restarting {
                attempt,
                reason: reason.clone(),
            },
        );
        eprintln!(
            "engine {alias}: {reason}; restarting in {:?}",
            backoff(attempt)
        );
        tokio::select! {
            _ = tokio::time::sleep(backoff(attempt)) => {}
            _ = stopped.changed() => break,
        }
    }
    let _ = std::fs::remove_file(&pid_file);
}

/// One server lifetime. `Ok` when asked to stop, `Err` with the reason when
/// it died or never became healthy.
async fn run_once(
    config: &ModelServer,
    pid_file: &Path,
    log_file: &Path,
    state: &Mutex<EngineState>,
    stopped: &mut watch::Receiver<bool>,
) -> Result<(), String> {
    set(state, EngineState::Starting);
    // Something else on the port would answer the health check in our
    // server's place, and the gateway would talk to it. Refuse instead.
    if std::net::TcpStream::connect_timeout(
        &std::net::SocketAddr::from(([127, 0, 0, 1], config.model.port)),
        Duration::from_millis(300),
    )
    .is_ok()
    {
        return Err(format!(
            "port {} is already in use by another process; stop it or change `port` in engine.toml",
            config.model.port
        ));
    }
    let log = open_log(log_file).map_err(|err| format!("engine log: {err}"))?;
    let log_err = log
        .try_clone()
        .map_err(|err| format!("engine log: {err}"))?;

    let mut command = tokio::process::Command::new(&config.server);
    command
        .args(config.args())
        .stdin(std::process::Stdio::null())
        .stdout(log)
        .stderr(log_err)
        .kill_on_drop(true);
    // Its own process group, so a terminal's Ctrl-C reaches the runner, which
    // then stops the engine deliberately, rather than both at once.
    #[cfg(unix)]
    command.process_group(0);
    let mut child = command
        .spawn()
        .map_err(|err| format!("could not start {}: {err}", config.server.display()))?;
    if let Some(pid) = child.id() {
        let _ = std::fs::write(pid_file, pid.to_string());
    }

    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(2))
        .build()
        .map_err(|err| err.to_string())?;
    let health = format!("http://127.0.0.1:{}/health", config.model.port);
    let deadline = Instant::now() + READY_DEADLINE;
    let mut ready = false;

    loop {
        tokio::select! {
            exit = child.wait() => {
                let status = exit.map(|s| s.to_string()).unwrap_or_else(|e| e.to_string());
                return Err(format!("the server exited ({status}); see {}", log_file.display()));
            }
            _ = stopped.changed() => {
                let _ = child.start_kill();
                let _ = child.wait().await;
                return Ok(());
            }
            _ = tokio::time::sleep(Duration::from_secs(1)) => {
                if ready {
                    continue;
                }
                let healthy = client
                    .get(&health)
                    .send()
                    .await
                    .is_ok_and(|response| response.status().is_success());
                if healthy {
                    ready = true;
                    set(state, EngineState::Ready);
                } else if Instant::now() > deadline {
                    let _ = child.start_kill();
                    let _ = child.wait().await;
                    return Err(format!(
                        "not healthy within {}s; see {}",
                        READY_DEADLINE.as_secs(),
                        log_file.display()
                    ));
                }
            }
        }
    }
}

fn open_log(path: &Path) -> std::io::Result<std::fs::File> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let too_big = std::fs::metadata(path).is_ok_and(|meta| meta.len() > LOG_LIMIT_BYTES);
    std::fs::OpenOptions::new()
        .create(true)
        .append(!too_big)
        .write(true)
        .truncate(too_big)
        .open(path)
}

/// Stop a server a previous runner left behind.
///
/// launchd stops the runner with SIGTERM, and a runner that restarts itself in
/// place replaces its own image; neither runs the code that stops the engine.
/// Without this the old server keeps the port and its memory, and the new one
/// cannot start. Only a process that is still our server binary is signalled,
/// so a recycled pid is left alone.
fn stop_leftover(pid_file: &Path, server: &Path) {
    let Some(pid) = std::fs::read_to_string(pid_file)
        .ok()
        .and_then(|text| text.trim().parse::<u32>().ok())
    else {
        return;
    };
    #[cfg(unix)]
    {
        let command = std::process::Command::new("ps")
            .args(["-o", "command=", "-p", &pid.to_string()])
            .output()
            .ok()
            .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_owned())
            .unwrap_or_default();
        // `contains`, not `starts_with`: a server started through an
        // interpreter or wrapper shows that first.
        if command.contains(&*server.to_string_lossy()) {
            let _ = std::process::Command::new("kill")
                .arg(pid.to_string())
                .status();
            // Give it a moment to release the port before a new one binds.
            for _ in 0..50 {
                let alive = std::process::Command::new("kill")
                    .args(["-0", &pid.to_string()])
                    .status()
                    .is_ok_and(|status| status.success());
                if !alive {
                    break;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }
    #[cfg(not(unix))]
    let _ = (pid, server);
    let _ = std::fs::remove_file(pid_file);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry() -> ModelEntry {
        ModelEntry {
            alias: "qwen3-coder-30b".into(),
            model: "/models/qwen \"coder\".gguf".into(),
            model_sha256: "ab".repeat(32),
            model_bytes: 42,
            port: DEFAULT_PORT,
            ctx_size: 32_768,
            parallel: 1,
            adapters: Vec::new(),
        }
    }

    fn config() -> EngineConfig {
        EngineConfig {
            build: PINNED_BUILD.into(),
            server: "/opt/engine/llama-server".into(),
            models: vec![entry()],
        }
    }

    fn with_specialist() -> EngineConfig {
        let mut config = config();
        config.models.push(ModelEntry {
            alias: "gpt-oss-20b".into(),
            model: "/models/gpt-oss-20b.gguf".into(),
            port: config.next_port(),
            adapters: vec![AdapterEntry {
                name: "gpt-oss-c2".into(),
                path: "/adapters/gpt-oss-c2.gguf".into(),
                sha256: "cd".repeat(32),
            }],
            ..entry()
        });
        config
    }

    #[test]
    fn the_written_config_reads_back_identically() {
        let written = with_specialist();
        let read: EngineConfig = toml::from_str(&written.to_toml()).unwrap();
        assert_eq!(read, written);
        assert_eq!(read.models[1].port, DEFAULT_PORT + 1);
    }

    #[test]
    fn the_server_listens_on_loopback_with_the_models_template() {
        let args = config().servers()[0].args();
        let after = |flag: &str| {
            args.iter()
                .position(|arg| arg == flag)
                .map(|i| args[i + 1].as_str())
        };
        assert_eq!(after("--host"), Some("127.0.0.1"));
        assert_eq!(after("--alias"), Some("qwen3-coder-30b"));
        assert!(args.iter().any(|arg| arg == "--jinja"));
        assert!(!args.iter().any(|arg| arg.starts_with("--lora")));
    }

    #[test]
    fn adapters_load_switched_off_so_only_a_specialist_turns_one_on() {
        let args = with_specialist().servers()[1].args();
        let lora = args.iter().position(|arg| arg == "--lora").unwrap();
        assert_eq!(args[lora + 1], "/adapters/gpt-oss-c2.gguf");
        assert!(args.iter().any(|arg| arg == "--lora-init-without-apply"));
    }

    #[test]
    fn a_bad_alias_repeated_port_or_limit_is_refused() {
        let mut bad = config();
        bad.models[0].alias = "qwen coder".into();
        assert!(bad.validate().is_err());
        let mut bad = config();
        bad.models[0].parallel = 0;
        assert!(bad.validate().is_err());
        let mut bad = with_specialist();
        bad.models[1].port = bad.models[0].port;
        assert!(bad.validate().is_err());
    }

    #[test]
    fn replacing_a_model_keeps_its_adapters() {
        let mut config = with_specialist();
        let port = config.models[1].port;
        config.upsert_model(ModelEntry {
            alias: "gpt-oss-20b".into(),
            port,
            ..entry()
        });
        assert_eq!(config.models.len(), 2);
        assert_eq!(config.models[1].adapters.len(), 1);
    }

    #[test]
    fn restarts_back_off_to_a_minute() {
        assert_eq!(backoff(1), Duration::from_secs(2));
        assert_eq!(backoff(2), Duration::from_secs(4));
        assert_eq!(backoff(5), Duration::from_secs(32));
        assert_eq!(backoff(6), Duration::from_secs(60));
        assert_eq!(backoff(40), Duration::from_secs(60));
    }

    #[test]
    fn the_server_binary_is_found_in_either_archive_layout() {
        let root = std::env::temp_dir().join(format!("farhelm-engine-{}", std::process::id()));
        let nested = root.join("llama-b11624");
        std::fs::create_dir_all(&nested).unwrap();
        std::fs::write(nested.join("llama-server"), b"").unwrap();
        assert_eq!(find_server(&root), Some(nested.join("llama-server")));
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// A stand-in for llama-server: answers `/health` on the `--port` it is
    /// given, or exits at once when `crash` is set.
    #[cfg(unix)]
    fn fake_engine(name: &str, crash: bool) -> (PathBuf, EngineConfig) {
        fake_engine_with(name, crash, 1)
    }

    #[cfg(unix)]
    fn fake_engine_with(name: &str, crash: bool, models: usize) -> (PathBuf, EngineConfig) {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = std::env::temp_dir().join(format!("farhelm-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let server = dir.join("llama-server");
        let body = if crash {
            "#!/bin/sh\nexit 3\n".to_owned()
        } else {
            "#!/bin/sh\n\
             while [ $# -gt 0 ]; do [ \"$1\" = --port ] && PORT=$2; shift; done\n\
             exec python3 -c \"import http.server as h\n\
             class H(h.BaseHTTPRequestHandler):\n\
             \x20def do_GET(s): s.send_response(200); s.end_headers(); s.wfile.write(b'ok')\n\
             \x20def log_message(s, *a): pass\n\
             h.HTTPServer(('127.0.0.1', $PORT), H).serve_forever()\"\n"
                .to_owned()
        };
        std::fs::write(&server, body).unwrap();
        std::fs::set_permissions(&server, std::fs::Permissions::from_mode(0o755)).unwrap();
        let model = dir.join("model.gguf");
        std::fs::write(&model, b"GGUF").unwrap();
        let config = EngineConfig {
            server,
            models: (0..models)
                .map(|index| ModelEntry {
                    alias: format!("model-{index}"),
                    model: model.clone(),
                    model_bytes: 4,
                    port: free_test_port(),
                    adapters: Vec::new(),
                    ..entry()
                })
                .collect(),
            ..config()
        };
        (dir, config)
    }

    /// A port below the OS's ephemeral range (49152 and up on macOS, 32768 up
    /// on Linux). A port taken with `bind(0)` and released can be handed to
    /// another test's `bind(0)` before the fake server binds it; these cannot.
    fn free_test_port() -> u16 {
        use std::sync::atomic::{AtomicU16, Ordering};
        static NEXT: AtomicU16 = AtomicU16::new(0);
        let base = 20_000 + (std::process::id() % 5_000) as u16;
        loop {
            let port = base + NEXT.fetch_add(1, Ordering::Relaxed) % 5_000;
            if std::net::TcpListener::bind(("127.0.0.1", port)).is_ok() {
                return port;
            }
        }
    }

    async fn wait_for(engine: &Engine, want: impl Fn(&EngineState) -> bool) -> EngineState {
        let first = || engine.states().remove(0).1;
        for _ in 0..200 {
            let state = first();
            if want(&state) {
                return state;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        first()
    }

    fn pid_of(dir: &Path, alias: &str) -> u32 {
        std::fs::read_to_string(dir.join(format!("engine-{alias}.pid")))
            .unwrap()
            .trim()
            .parse()
            .unwrap()
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn the_engine_becomes_ready_and_is_stopped_on_shutdown() {
        let (dir, config) = fake_engine("ready", false);
        let port = config.models[0].port;
        let engine = Engine::spawn(config, dir.clone());
        let state = wait_for(&engine, |s| *s == EngineState::Ready).await;
        assert_eq!(state, EngineState::Ready);
        let pid = pid_of(&dir, "model-0");

        engine.shutdown().await;
        assert!(!dir.join("engine-model-0.pid").exists());
        let alive = std::process::Command::new("kill")
            .args(["-0", &pid.to_string()])
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap()
            .success();
        assert!(!alive, "the server outlived the runner's shutdown");
        assert!(std::net::TcpStream::connect(("127.0.0.1", port)).is_err());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn every_model_gets_its_own_server() {
        let (dir, config) = fake_engine_with("pair", false, 2);
        let engine = Engine::spawn(config, dir.clone());
        for _ in 0..200 {
            if engine
                .states()
                .iter()
                .all(|(_, state)| *state == EngineState::Ready)
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        let states = engine.states();
        assert_eq!(states.len(), 2);
        assert!(
            states.iter().all(|(_, state)| *state == EngineState::Ready),
            "{states:?}"
        );
        assert_ne!(pid_of(&dir, "model-0"), pid_of(&dir, "model-1"));
        engine.shutdown().await;
        assert!(!dir.join("engine-model-1.pid").exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_crashing_server_is_restarted_with_backoff() {
        let (dir, config) = fake_engine("crash", true);
        let engine = Engine::spawn(config, dir.clone());
        let state = wait_for(&engine, |s| matches!(s, EngineState::Restarting { .. })).await;
        match state {
            EngineState::Restarting { attempt, reason } => {
                assert_eq!(attempt, 1);
                assert!(reason.contains("exited"), "{reason}");
            }
            other => panic!("expected a restart, got {other:?}"),
        }
        engine.shutdown().await;
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn another_process_on_the_port_is_not_mistaken_for_the_engine() {
        let (dir, mut config) = fake_engine("squatter", false);
        // Held from the moment it is chosen, so no parallel test can take it.
        let squatter = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        config.models[0].port = squatter.local_addr().unwrap().port();
        let engine = Engine::spawn(config, dir.clone());
        let state = wait_for(&engine, |s| matches!(s, EngineState::Restarting { .. })).await;
        match state {
            EngineState::Restarting { reason, .. } => {
                assert!(reason.contains("already in use"), "{reason}")
            }
            other => panic!("expected a refusal, got {other:?}"),
        }
        engine.shutdown().await;
        drop(squatter);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_server_left_by_a_previous_runner_is_stopped_first() {
        let (dir, config) = fake_engine("leftover", false);
        let leftover = std::process::Command::new(&config.server)
            .args(config.servers()[0].args())
            .spawn()
            .unwrap();
        std::fs::write(dir.join("engine-model-0.pid"), leftover.id().to_string()).unwrap();

        let engine = Engine::spawn(config, dir.clone());
        let state = wait_for(&engine, |s| *s == EngineState::Ready).await;
        assert_eq!(state, EngineState::Ready);
        let mut leftover = leftover;
        assert!(
            leftover.try_wait().unwrap().is_some(),
            "the previous server was left running"
        );
        engine.shutdown().await;
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_changed_model_stops_the_engine_before_it_starts() {
        let dir = std::env::temp_dir().join(format!("farhelm-preflight-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let server = dir.join("llama-server");
        let model = dir.join("model.gguf");
        std::fs::write(&server, b"").unwrap();
        std::fs::write(&model, b"GGUF and then some").unwrap();
        let mut target = config().servers().remove(0);
        target.server = server;
        target.model.model = model;
        target.model.model_bytes = 3;
        let err = target.preflight().unwrap_err();
        assert!(err.0.contains("reinstall"), "{err}");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
