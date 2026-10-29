//! `farhelm eval`: score registry models on a project's held-out suite.
//!
//! A suite is a folder: `suite.toml`, the system prompt, the JSON schema the
//! answer must match, and `items.jsonl` with each item's prompt and the label a
//! person gave it. Every model is run several times, because one run is not a
//! score: on lacuna's e030 audit, two identical runs at temperature 0 changed
//! 6 of 54 labels and moved kappa from 0.11 to 0.21 (ADR 0011).
//!
//! Calls go through the gateway like any other, under the `eval` client's
//! session, so they are in the ledger and kept apart from the projects' own
//! use. Each run has its own cache scope: a repeated run that read the last
//! run's answers from the cache would measure nothing.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use farhelm_gateway::{CompleteRequest, Gateway, GatewayConfig, ProviderClient};
use farhelm_proto::types::TaskType;
use farhelm_sqlite::SqliteStore;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// The session evaluation calls are recorded under: the `eval` client's.
const SESSION: &str = "client-eval";

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SuiteFile {
    name: String,
    system_file: PathBuf,
    schema_file: PathBuf,
    label_field: String,
    labels: Vec<String>,
    #[serde(default = "default_max_tokens")]
    max_tokens: u32,
}

fn default_max_tokens() -> u32 {
    1_500
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Item {
    pub id: String,
    pub user: String,
    /// The label a person gave this item; items without one are answered but
    /// not scored.
    #[serde(default)]
    pub expected: Option<String>,
}

#[derive(Debug)]
pub struct Suite {
    pub name: String,
    pub system: String,
    pub schema: Value,
    pub label_field: String,
    pub labels: Vec<String>,
    pub max_tokens: u32,
    pub items: Vec<Item>,
}

impl Suite {
    pub fn load(dir: &Path) -> Result<Self, String> {
        let read = |name: &Path| {
            std::fs::read_to_string(dir.join(name))
                .map_err(|err| format!("{}: {err}", dir.join(name).display()))
        };
        let file: SuiteFile = toml::from_str(&read(Path::new("suite.toml"))?)
            .map_err(|err| format!("suite.toml: {err}"))?;
        let schema: Value = serde_json::from_str(&read(&file.schema_file)?)
            .map_err(|err| format!("{}: {err}", file.schema_file.display()))?;
        if !schema.is_object() {
            return Err(format!(
                "{} must hold a JSON object",
                file.schema_file.display()
            ));
        }
        let mut items = Vec::new();
        for (line, text) in read(Path::new("items.jsonl"))?.lines().enumerate() {
            if text.trim().is_empty() {
                continue;
            }
            let item: Item = serde_json::from_str(text)
                .map_err(|err| format!("items.jsonl line {}: {err}", line + 1))?;
            items.push(item);
        }
        let suite = Self {
            name: file.name,
            system: read(&file.system_file)?,
            schema,
            label_field: file.label_field,
            labels: file.labels,
            max_tokens: file.max_tokens,
            items,
        };
        suite.validate()?;
        Ok(suite)
    }

    fn validate(&self) -> Result<(), String> {
        if !crate::clients::valid_name(&self.name) {
            return Err(format!(
                "suite name `{}` must be ASCII letters, digits, '-' or '_'",
                self.name
            ));
        }
        let labels: BTreeSet<&str> = self.labels.iter().map(String::as_str).collect();
        if labels.len() < 2 || labels.len() != self.labels.len() {
            return Err("labels must list at least two distinct labels".into());
        }
        let mut ids = BTreeSet::new();
        for item in &self.items {
            if !ids.insert(item.id.as_str()) {
                return Err(format!("item id `{}` appears twice", item.id));
            }
            if let Some(expected) = &item.expected
                && !labels.contains(expected.as_str())
            {
                return Err(format!(
                    "item `{}` expects `{expected}`, which is not one of the labels",
                    item.id
                ));
            }
        }
        if self.scored() == 0 {
            return Err("no item has an expected label, so nothing can be scored".into());
        }
        Ok(())
    }

    fn scored(&self) -> usize {
        self.items
            .iter()
            .filter(|item| item.expected.is_some())
            .count()
    }

    /// The label in a model's answer, when the answer is JSON holding one of
    /// the suite's labels in `label_field`.
    pub fn label_of(&self, text: &str) -> Option<String> {
        let text = text.trim();
        // Some models fence JSON even when asked for the bare object.
        let text = text
            .strip_prefix("```json")
            .or_else(|| text.strip_prefix("```"))
            .and_then(|rest| rest.strip_suffix("```"))
            .unwrap_or(text);
        let value: Value = serde_json::from_str(text.trim()).ok()?;
        let label = value.get(&self.label_field)?.as_str()?;
        self.labels
            .iter()
            .any(|known| known == label)
            .then(|| label.to_owned())
    }

    fn index_of(&self, label: &str) -> usize {
        self.labels
            .iter()
            .position(|known| known == label)
            .expect("labels are validated against the suite")
    }

    /// One run's agreement with the expected labels.
    pub fn score(&self, answers: &BTreeMap<String, Option<String>>) -> RunScore {
        let mut pairs = Vec::new();
        let mut failed = 0;
        for item in &self.items {
            match answers.get(&item.id) {
                Some(Some(label)) => {
                    if let Some(expected) = &item.expected {
                        pairs.push((self.index_of(expected), self.index_of(label)));
                    }
                }
                _ => failed += 1,
            }
        }
        let exact = (!pairs.is_empty())
            .then(|| pairs.iter().filter(|(a, b)| a == b).count() as f64 / pairs.len() as f64);
        RunScore {
            scored: pairs.len(),
            failed,
            exact,
            kappa: cohens_kappa(&pairs, self.labels.len()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RunScore {
    /// Items with an expected label that the model answered with a label.
    pub scored: usize,
    /// Items the model did not answer with a usable label.
    pub failed: usize,
    pub exact: Option<f64>,
    pub kappa: Option<f64>,
}

/// Cohen's kappa for `(expected, answered)` category pairs: agreement beyond
/// what the two label distributions would give by chance. `None` when it is
/// undefined (no pairs, or both sides use one and the same category).
pub fn cohens_kappa(pairs: &[(usize, usize)], categories: usize) -> Option<f64> {
    if pairs.is_empty() {
        return None;
    }
    let n = pairs.len() as f64;
    let mut a = vec![0.0; categories];
    let mut b = vec![0.0; categories];
    let mut agree = 0.0;
    for &(x, y) in pairs {
        a[x] += 1.0;
        b[y] += 1.0;
        if x == y {
            agree += 1.0;
        }
    }
    let observed = agree / n;
    let chance: f64 = a.iter().zip(&b).map(|(x, y)| (x / n) * (y / n)).sum();
    (chance < 1.0).then(|| (observed - chance) / (1.0 - chance))
}

/// How often two runs gave the same label, over items both answered.
pub fn run_agreement(
    a: &BTreeMap<String, Option<String>>,
    b: &BTreeMap<String, Option<String>>,
) -> Option<f64> {
    let both: Vec<bool> = a
        .iter()
        .filter_map(|(id, label)| Some(label.as_ref()? == b.get(id)?.as_ref()?))
        .collect();
    (!both.is_empty()).then(|| both.iter().filter(|same| **same).count() as f64 / both.len() as f64)
}

#[derive(Debug, Serialize)]
struct ModelReport {
    /// As asked for (`think`).
    model: String,
    /// What the registry resolved it to (`gpt-oss-20b`), the deployment the
    /// score belongs to.
    deployment: Option<String>,
    runs: Vec<RunScore>,
    /// Mean exact agreement between each pair of runs.
    run_agreement: Option<f64>,
    answers: Vec<BTreeMap<String, Option<String>>>,
}

pub struct Options {
    pub suite_dir: PathBuf,
    pub models: Vec<String>,
    pub runs: usize,
    pub models_config: PathBuf,
    pub db: PathBuf,
    /// Where the report is written: `<dir>/<suite>-<unix ms>.json`.
    pub reports: PathBuf,
}

/// Run a suite and write its report. Prints a table as it goes.
pub async fn run(options: Options) -> Result<PathBuf, Box<dyn std::error::Error>> {
    let suite = Suite::load(&options.suite_dir)?;
    let client = ProviderClient::from_path(&options.models_config)?;
    for model in &options.models {
        if client.canonical(model).is_none() {
            return Err(format!("`{model}` is not in the model registry").into());
        }
    }
    let store = Arc::new(SqliteStore::open(&options.db)?);
    let machine_id = crate::state::ensure_machine(&store);
    crate::messages::ensure_bucket_in(&store, &machine_id, SESSION)?;
    let mut config = GatewayConfig {
        compaction: None,
        ..GatewayConfig::default()
    };
    if let Some(models) = client.models() {
        config.models = models;
    }
    config.max_tokens = config.max_tokens.max(suite.max_tokens);
    let deployments: Vec<Option<String>> = options
        .models
        .iter()
        .map(|model| client.canonical(model))
        .collect();
    let gateway = Gateway::new(store, client, config);
    let started = farhelm_app::time::now_ms();

    println!(
        "{}: {} items, {} with a person's label; {} run(s) per model",
        suite.name,
        suite.items.len(),
        suite.scored(),
        options.runs
    );
    let mut reports = Vec::new();
    for (model, deployment) in options.models.iter().zip(deployments) {
        let mut runs = Vec::new();
        let mut answers = Vec::new();
        for run in 0..options.runs {
            let scope = format!("eval:{}:{started}:{model}:{run}", suite.name);
            let mut labels = BTreeMap::new();
            for item in &suite.items {
                let label = ask(&gateway, &suite, item, model, &scope).await;
                labels.insert(item.id.clone(), label);
            }
            let score = suite.score(&labels);
            println!(
                "  {model:<16} run {}  kappa {}  exact {}  failed {}",
                run + 1,
                shown(score.kappa),
                shown(score.exact),
                score.failed
            );
            runs.push(score);
            answers.push(labels);
        }
        let mut pairs = Vec::new();
        for (i, a) in answers.iter().enumerate() {
            for b in &answers[i + 1..] {
                pairs.extend(run_agreement(a, b));
            }
        }
        let agreement = (!pairs.is_empty()).then(|| pairs.iter().sum::<f64>() / pairs.len() as f64);
        reports.push(ModelReport {
            model: model.clone(),
            deployment,
            runs,
            run_agreement: agreement,
            answers,
        });
    }

    println!();
    println!(
        "{:<16} {:<28} {:>7} {:>15} {:>7} {:>7} {:>9}",
        "model", "deployment", "kappa", "kappa range", "exact", "failed", "run-run"
    );
    for report in &reports {
        let kappas: Vec<f64> = report.runs.iter().filter_map(|run| run.kappa).collect();
        let exacts: Vec<f64> = report.runs.iter().filter_map(|run| run.exact).collect();
        let failed: usize = report.runs.iter().map(|run| run.failed).sum();
        let range = match (min(&kappas), max(&kappas)) {
            (Some(lo), Some(hi)) => format!("{lo:.2} to {hi:.2}"),
            _ => "-".into(),
        };
        println!(
            "{:<16} {:<28} {:>7} {:>15} {:>7} {:>7} {:>9}",
            report.model,
            report.deployment.as_deref().unwrap_or("-"),
            shown(mean(&kappas)),
            range,
            shown(mean(&exacts)),
            failed,
            shown(report.run_agreement)
        );
    }

    std::fs::create_dir_all(&options.reports)?;
    let path = options
        .reports
        .join(format!("{}-{started}.json", suite.name));
    let report = json!({
        "suite": suite.name,
        "suite_dir": options.suite_dir,
        "items": suite.items.len(),
        "scored_items": suite.scored(),
        "labels": suite.labels,
        "runs_per_model": options.runs,
        "started_at_ms": started,
        "models": reports,
    });
    std::fs::write(&path, serde_json::to_vec_pretty(&report)?)?;
    Ok(path)
}

async fn ask(
    gateway: &crate::state::RunnerGateway,
    suite: &Suite,
    item: &Item,
    model: &str,
    scope: &str,
) -> Option<String> {
    let mut request = CompleteRequest::new(SESSION, TaskType::Triage, item.user.clone());
    request.stable.system = suite.system.clone();
    request.model = Some(model.to_owned());
    request.cache_scope = Some(scope.to_owned());
    request.max_tokens = Some(suite.max_tokens);
    request.loop_guard = false;
    request.sampling.temperature = Some(0.0);
    request.sampling.response_format = Some(json!({
        "type": "json_schema",
        "json_schema": { "name": "answer", "schema": suite.schema, "strict": true },
    }));
    match gateway.complete(request).await {
        Ok(response) => suite.label_of(&response.text),
        // A failed call is a failed item, counted in the report; one model
        // error must not end a run that has already spent minutes.
        Err(_) => None,
    }
}

fn mean(values: &[f64]) -> Option<f64> {
    (!values.is_empty()).then(|| values.iter().sum::<f64>() / values.len() as f64)
}

fn min(values: &[f64]) -> Option<f64> {
    values.iter().copied().reduce(f64::min)
}

fn max(values: &[f64]) -> Option<f64> {
    values.iter().copied().reduce(f64::max)
}

fn shown(value: Option<f64>) -> String {
    value.map_or("-".into(), |value| format!("{value:.2}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn suite() -> Suite {
        let item = |id: &str, expected: Option<&str>| Item {
            id: id.into(),
            user: format!("item {id}"),
            expected: expected.map(str::to_owned),
        };
        Suite {
            name: "demo".into(),
            system: "Grade it.".into(),
            schema: json!({ "type": "object" }),
            label_field: "grade".into(),
            labels: vec!["yes".into(), "no".into()],
            max_tokens: 100,
            items: vec![
                item("1", Some("yes")),
                item("2", Some("yes")),
                item("3", Some("no")),
                item("4", Some("no")),
                item("5", None),
            ],
        }
    }

    fn answers(labels: &[(&str, Option<&str>)]) -> BTreeMap<String, Option<String>> {
        labels
            .iter()
            .map(|(id, label)| ((*id).to_owned(), label.map(str::to_owned)))
            .collect()
    }

    #[test]
    fn kappa_matches_the_textbook_values() {
        // Perfect agreement over two balanced categories.
        assert_eq!(
            cohens_kappa(&[(0, 0), (0, 0), (1, 1), (1, 1)], 2),
            Some(1.0)
        );
        // Half right with balanced marginals is chance.
        assert_eq!(
            cohens_kappa(&[(0, 0), (0, 1), (1, 0), (1, 1)], 2),
            Some(0.0)
        );
        // 70 agreements in 100 with marginals 60/40 on both sides: chance is
        // 0.52, so kappa is (0.70 - 0.52) / 0.48.
        let mut pairs = vec![(0, 0); 45];
        pairs.extend(vec![(0, 1); 15]);
        pairs.extend(vec![(1, 0); 15]);
        pairs.extend(vec![(1, 1); 25]);
        assert!((cohens_kappa(&pairs, 2).unwrap() - 0.375).abs() < 1e-9);
        // One shared category leaves nothing to measure.
        assert_eq!(cohens_kappa(&[(0, 0), (0, 0)], 2), None);
        assert_eq!(cohens_kappa(&[], 2), None);
    }

    #[test]
    fn a_run_is_scored_on_labelled_items_and_counts_failures() {
        let suite = suite();
        let run = answers(&[
            ("1", Some("yes")),
            ("2", Some("no")),
            ("3", Some("no")),
            ("4", None),
            ("5", Some("yes")),
        ]);
        let score = suite.score(&run);
        assert_eq!(score.scored, 3, "item 5 has no expected label");
        assert_eq!(score.failed, 1);
        assert!((score.exact.unwrap() - 2.0 / 3.0).abs() < 1e-9);
    }

    #[test]
    fn only_a_known_label_in_the_named_field_counts() {
        let suite = suite();
        assert_eq!(
            suite.label_of(r#"{"grade":"yes","reason":"x"}"#).as_deref(),
            Some("yes")
        );
        assert_eq!(
            suite
                .label_of("```json\n{\"grade\":\"no\"}\n```")
                .as_deref(),
            Some("no")
        );
        assert_eq!(suite.label_of(r#"{"grade":"maybe"}"#), None);
        assert_eq!(suite.label_of(r#"{"label":"yes"}"#), None);
        assert_eq!(suite.label_of("yes"), None);
    }

    #[test]
    fn runs_agree_on_items_both_answered() {
        let a = answers(&[("1", Some("yes")), ("2", Some("no")), ("3", None)]);
        let b = answers(&[("1", Some("yes")), ("2", Some("yes")), ("3", Some("no"))]);
        assert_eq!(run_agreement(&a, &b), Some(0.5));
    }

    #[test]
    fn a_suite_folder_loads_and_bad_ones_are_refused() {
        let dir = std::env::temp_dir().join(format!("farhelm-eval-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let write = |name: &str, text: &str| std::fs::write(dir.join(name), text).unwrap();
        write(
            "suite.toml",
            "name = \"demo\"\nsystem_file = \"system.md\"\nschema_file = \"schema.json\"\n\
             label_field = \"grade\"\nlabels = [\"yes\", \"no\"]\n",
        );
        write("system.md", "Grade it.");
        write("schema.json", r#"{"type":"object"}"#);
        write(
            "items.jsonl",
            "{\"id\":\"1\",\"user\":\"a\",\"expected\":\"yes\"}\n\n{\"id\":\"2\",\"user\":\"b\"}\n",
        );
        let suite = Suite::load(&dir).unwrap();
        assert_eq!(
            (suite.items.len(), suite.scored(), suite.max_tokens),
            (2, 1, 1_500)
        );

        write(
            "items.jsonl",
            "{\"id\":\"1\",\"user\":\"a\",\"expected\":\"maybe\"}\n",
        );
        assert!(
            Suite::load(&dir)
                .unwrap_err()
                .contains("not one of the labels")
        );
        write("items.jsonl", "{\"id\":\"1\",\"user\":\"a\"}\n");
        assert!(
            Suite::load(&dir)
                .unwrap_err()
                .contains("nothing can be scored")
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
