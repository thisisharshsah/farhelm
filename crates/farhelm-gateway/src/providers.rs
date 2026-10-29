//! Explicit model/provider selection. The configured path never falls back to
//! the legacy client, another model, or another provider.

use std::{collections::BTreeMap, fmt, io::Read, net::IpAddr, path::Path};

use farhelm_domain::price::{ModelPrice, TokenRates};
use farhelm_proto::types::Tier;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{
    credential::CredentialError,
    dispatch::{AnthropicClient, DispatchError, ModelClient, ModelRequest, ModelResponse},
    openai::OpenAiClient,
    prompt::ContentBlock,
    router::Models,
};

pub const MODELS_CONFIG_ENV: &str = "FARHELM_MODELS_CONFIG";
const MAX_CONFIG_BYTES: u64 = 1024 * 1024;
const MAX_ENTRIES: usize = 256;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigError(pub String);

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ConfigError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum DataPolicy {
    LocalOnly,
    CloudAllowed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum DataLocation {
    Local,
    Cloud,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ProviderKind {
    OpenaiCompatible,
    Openrouter,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    version: u32,
    policy: DataPolicy,
    routes: Routes,
    providers: BTreeMap<String, ProviderConfig>,
    models: BTreeMap<String, ModelConfig>,
    /// Purpose names projects ask for (`think`, `companion`), each pointing
    /// at a model or a model with one of its adapters (`gpt-oss-20b:fast`).
    /// Moving an alias changes what serves a purpose without any project
    /// changing its setting; the ledger records exactly what ran.
    #[serde(default)]
    aliases: BTreeMap<String, String>,
}

/// A name a request may use: `model`, `model:adapter`, or a pinned
/// `model:adapter@vN`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ModelRef<'a> {
    model: &'a str,
    adapter: Option<&'a str>,
    version: Option<u32>,
}

fn parse_ref(name: &str) -> Option<ModelRef<'_>> {
    let (model, rest) = match name.split_once(':') {
        Some((model, rest)) => (model, Some(rest)),
        None => (name, None),
    };
    let (adapter, version) = match rest {
        None => (None, None),
        Some(rest) => match rest.split_once('@') {
            Some((adapter, version)) => (
                Some(adapter),
                Some(
                    version
                        .strip_prefix('v')?
                        .parse::<u32>()
                        .ok()
                        .filter(|v| *v > 0)?,
                ),
            ),
            None => (Some(rest), None),
        },
    };
    if model.is_empty() || adapter.is_some_and(str::is_empty) {
        return None;
    }
    Some(ModelRef {
        model,
        adapter,
        version,
    })
}

impl Config {
    /// The reference a name means: an alias's target, or the name itself.
    fn reference<'a>(&'a self, name: &'a str) -> Option<ModelRef<'a>> {
        let target = self.aliases.get(name).map_or(name, String::as_str);
        let reference = parse_ref(target)?;
        let model = self.models.get(reference.model)?;
        if let Some(adapter) = reference.adapter {
            let config = model.adapters.get(adapter)?;
            let version = reference.version.unwrap_or(config.current);
            config.versions.iter().find(|v| v.version == version)?;
        }
        Some(reference)
    }

    /// The exact model a name serves: `model` or `model:adapter@vN`.
    fn canonical(&self, name: &str) -> Option<String> {
        let reference = self.reference(name)?;
        Some(match reference.adapter {
            None => reference.model.to_owned(),
            Some(adapter) => {
                let version = reference
                    .version
                    .unwrap_or(self.models[reference.model].adapters[adapter].current);
                format!("{}:{adapter}@v{version}", reference.model)
            }
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Routes {
    small: String,
    large: String,
    frontier: String,
}

impl Routes {
    fn models(&self) -> Models {
        Models {
            small: self.small.clone(),
            large: self.large.clone(),
            frontier: self.frontier.clone(),
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ProviderConfig {
    kind: ProviderKind,
    base_url: String,
    data_location: DataLocation,
    api_key_env: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ModelConfig {
    provider: String,
    model: String,
    tools: bool,
    max_output_tokens: u32,
    pricing: Option<Pricing>,
    /// Chat-template settings sent with every request to this model
    /// (llama.cpp's `chat_template_kwargs`). Scalars only; `openai_compatible`
    /// servers only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    chat_template_kwargs: Option<serde_json::Map<String, serde_json::Value>>,
    /// The adapters trained for this model, by name. A request selects one as
    /// `model:adapter`; the model on its own uses none.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    adapters: BTreeMap<String, AdapterConfig>,
    /// What this model is and where it came from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    card: Option<ModelCard>,
}

/// A model's record: who made it, and the facts of this deployment.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelCard {
    #[serde(default)]
    pub owner: Option<String>,
    #[serde(default)]
    pub notes: Option<String>,
}

/// One adapter of a model, across its versions. `model:adapter` serves the
/// `current` version; `model:adapter@vN` pins one.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AdapterConfig {
    pub current: u32,
    #[serde(default)]
    pub purpose: Option<String>,
    /// The project or person it was trained for.
    #[serde(default)]
    pub owner: Option<String>,
    /// Template settings the adapter was trained with (Qwen3.5's
    /// `enable_thinking = false`, say), merged over the model's.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chat_template_kwargs: Option<serde_json::Map<String, serde_json::Value>>,
    pub versions: Vec<AdapterVersion>,
}

/// One trained version: where the server holds it, and its record.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AdapterVersion {
    pub version: u32,
    /// Its position among the adapters the model's server loaded
    /// (`farhelm engine status` lists them).
    pub lora_id: u32,
    #[serde(default = "full_scale")]
    pub scale: f32,
    /// The exact weights it was trained on, when that differs from what is
    /// served (an MLX 4-bit base for a GGUF 8-bit deployment, say).
    #[serde(default)]
    pub trained_on: Option<String>,
    #[serde(default)]
    pub training: Option<String>,
    #[serde(default)]
    pub evaluation: Option<String>,
    #[serde(default)]
    pub notes: Option<String>,
}

fn full_scale() -> f32 {
    1.0
}

/// One registry model, for listings.
#[derive(Debug, Clone, PartialEq)]
pub struct ModelSummary {
    pub name: String,
    pub provider: String,
    pub upstream: String,
    pub card: Option<ModelCard>,
    pub adapters: Vec<AdapterSummary>,
    /// Aliases pointing at the model on its own.
    pub aliases: Vec<String>,
    /// Which routing slots use it.
    pub routes: Vec<&'static str>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AdapterSummary {
    pub name: String,
    pub config: AdapterConfig,
    /// Aliases pointing at `model:adapter` (any version).
    pub aliases: Vec<String>,
}

/// What a request switches on: an adapter's position on its server, and how
/// strongly.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AdapterUse {
    pub id: u32,
    pub scale: f32,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Pricing {
    input_per_mtok: f64,
    output_per_mtok: f64,
    cache_write_per_mtok: Option<f64>,
    cache_read_per_mtok: Option<f64>,
}

impl Pricing {
    fn rates(&self) -> Result<TokenRates, ConfigError> {
        TokenRates::new(
            self.input_per_mtok,
            self.output_per_mtok,
            self.cache_write_per_mtok.unwrap_or(self.input_per_mtok),
            self.cache_read_per_mtok.unwrap_or(self.input_per_mtok),
        )
        .map_err(|_| ConfigError("model pricing must be finite and nonnegative".into()))
    }
}

/// Runtime registry owned by one gateway. The operator configuration is read
/// once at startup; changed configuration requires a restart.
pub struct ProviderRegistry {
    config: Config,
    clients: BTreeMap<String, OpenAiClient>,
    rates: BTreeMap<String, TokenRates>,
    fingerprint: String,
}

pub enum ProviderClient {
    Legacy(AnthropicClient),
    Configured(Box<ProviderRegistry>),
}

/// Nonsecret deployment identity for evaluation reports. This is an operator
/// declaration, not an attestation of the weights or runtime behind an endpoint.
#[derive(Debug, Clone, Serialize)]
pub struct ConfiguredDeployment {
    pub alias: String,
    pub provider: String,
    pub kind: &'static str,
    pub data_location: &'static str,
    pub model: String,
    pub tools: bool,
    pub max_output_tokens: u32,
    pub configuration_sha256: String,
}

impl From<AnthropicClient> for ProviderClient {
    fn from(value: AnthropicClient) -> Self {
        Self::from_legacy(value)
    }
}

impl ProviderClient {
    pub fn deployment(&self, alias: &str) -> Result<ConfiguredDeployment, DispatchError> {
        let Self::Configured(registry) = self else {
            return Err(DispatchError::Decode(
                "evaluation requires an explicit configured provider".into(),
            ));
        };
        let resolved = registry.resolve(alias)?;
        let (model, provider) = (resolved.model, resolved.provider);
        // Deliberately exclude resolved credentials, endpoint strings and the
        // credential-sensitive cache fingerprint from the public report.
        let encoded = serde_json::to_vec(&registry.config)
            .map_err(|_| DispatchError::Decode("could not identify model configuration".into()))?;
        Ok(ConfiguredDeployment {
            alias: alias.into(),
            provider: model.provider.clone(),
            kind: match provider.kind {
                ProviderKind::OpenaiCompatible => "openai_compatible",
                ProviderKind::Openrouter => "openrouter",
            },
            data_location: match provider.data_location {
                DataLocation::Local => "local",
                DataLocation::Cloud => "cloud",
            },
            model: model.model.clone(),
            tools: model.tools,
            max_output_tokens: model.max_output_tokens,
            configuration_sha256: format!("{:x}", Sha256::digest(encoded)),
        })
    }

    pub fn from_legacy(client: AnthropicClient) -> Self {
        Self::Legacy(client)
    }

    /// Explicit configuration takes precedence over legacy environment
    /// variables. An invalid selected file is an error, never a legacy fallback.
    pub fn from_env() -> Result<Option<Self>, ConfigError> {
        match std::env::var_os(MODELS_CONFIG_ENV) {
            Some(path) => Self::from_path(Path::new(&path)).map(Some),
            None => Ok(AnthropicClient::from_env().map(Self::from_legacy)),
        }
    }

    pub fn from_path(path: &Path) -> Result<Self, ConfigError> {
        let mut file = std::fs::File::open(path)
            .map_err(|err| ConfigError(format!("could not open model configuration: {err}")))?
            .take(MAX_CONFIG_BYTES + 1);
        let mut source = String::new();
        file.read_to_string(&mut source)
            .map_err(|err| ConfigError(format!("could not read model configuration: {err}")))?;
        Self::from_toml(&source)
    }

    pub fn from_toml(source: &str) -> Result<Self, ConfigError> {
        Self::configured_from(source, |key| std::env::var(key).ok())
    }

    fn configured_from(
        source: &str,
        get_env: impl Fn(&str) -> Option<String>,
    ) -> Result<Self, ConfigError> {
        ProviderRegistry::new(source, get_env).map(|registry| Self::Configured(Box::new(registry)))
    }

    /// Every model alias the registry declares, in order. Empty for the
    /// legacy Anthropic client, which has no registry.
    /// Every name a request may use, in order: each model, each
    /// `model:adapter`, then the aliases. Pinned `@vN` forms are accepted
    /// too but not listed. Empty for the legacy Anthropic client.
    pub fn model_aliases(&self) -> Vec<String> {
        let Self::Configured(registry) = self else {
            return Vec::new();
        };
        let config = &registry.config;
        let mut names = Vec::new();
        for (name, model) in &config.models {
            names.push(name.clone());
            names.extend(
                model
                    .adapters
                    .keys()
                    .map(|adapter| format!("{name}:{adapter}")),
            );
        }
        names.extend(config.aliases.keys().cloned());
        names
    }

    /// Whether the registry serves this name (model, `model:adapter`, a
    /// pinned version, or an alias).
    pub fn declares(&self, name: &str) -> bool {
        match self {
            Self::Legacy(_) => false,
            Self::Configured(registry) => registry.config.reference(name).is_some(),
        }
    }

    /// For an alias, what it points at now; `None` for any other name.
    pub fn alias_target(&self, name: &str) -> Option<String> {
        match self {
            Self::Legacy(_) => None,
            Self::Configured(registry) => registry.config.aliases.get(name).cloned(),
        }
    }

    /// The exact model a name serves (`model` or `model:adapter@vN`).
    pub fn canonical(&self, name: &str) -> Option<String> {
        match self {
            Self::Legacy(_) => None,
            Self::Configured(registry) => registry.config.canonical(name),
        }
    }

    /// Every registry model with its card, adapters, aliases and routes.
    /// Empty for the legacy client.
    pub fn summaries(&self) -> Vec<ModelSummary> {
        let Self::Configured(registry) = self else {
            return Vec::new();
        };
        let config = &registry.config;
        let pointing_at = |model: &str, adapter: Option<&str>| -> Vec<String> {
            config
                .aliases
                .iter()
                .filter(|(_, target)| {
                    parse_ref(target).is_some_and(|r| r.model == model && r.adapter == adapter)
                })
                .map(|(alias, _)| alias.clone())
                .collect()
        };
        config
            .models
            .iter()
            .map(|(name, model)| ModelSummary {
                name: name.clone(),
                provider: model.provider.clone(),
                upstream: model.model.clone(),
                card: model.card.clone(),
                adapters: model
                    .adapters
                    .iter()
                    .map(|(adapter, config)| AdapterSummary {
                        name: adapter.clone(),
                        config: config.clone(),
                        aliases: pointing_at(name, Some(adapter)),
                    })
                    .collect(),
                aliases: pointing_at(name, None),
                routes: [
                    ("small", &config.routes.small),
                    ("large", &config.routes.large),
                    ("frontier", &config.routes.frontier),
                ]
                .into_iter()
                .filter(|(_, route)| {
                    config
                        .reference(route)
                        .is_some_and(|r| r.model == name && r.adapter.is_none())
                })
                .map(|(slot, _)| slot)
                .collect(),
            })
            .collect()
    }

    pub fn models(&self) -> Option<Models> {
        match self {
            Self::Legacy(_) => None,
            Self::Configured(registry) => Some(registry.config.routes.models()),
        }
    }

    pub fn provider_name(&self) -> &'static str {
        match self {
            Self::Legacy(_) => "anthropic",
            Self::Configured(_) => "configured",
        }
    }

    pub fn credential_kind(&self) -> &'static str {
        match self {
            Self::Legacy(client) => client.credential_kind(),
            Self::Configured(_) => "provider configuration",
        }
    }

    pub fn credential_ready(&self) -> Result<(), CredentialError> {
        match self {
            Self::Legacy(client) => client.credential_ready(),
            // Configured credentials are resolved and checked during loading.
            Self::Configured(_) => Ok(()),
        }
    }
}

impl ModelClient for ProviderClient {
    async fn complete(&self, request: ModelRequest) -> Result<ModelResponse, DispatchError> {
        match self {
            Self::Legacy(client) => client.complete(request).await,
            Self::Configured(registry) => registry.complete(request).await,
        }
    }

    fn supports_batch(&self) -> bool {
        match self {
            Self::Legacy(client) => client.supports_batch(),
            Self::Configured(_) => false,
        }
    }

    fn model_price(&self, model: &str) -> Result<ModelPrice, DispatchError> {
        match self {
            Self::Legacy(client) => client.model_price(model),
            Self::Configured(registry) => registry.model_price(model),
        }
    }

    fn billing_rates(&self, model: &str) -> Option<TokenRates> {
        match self {
            Self::Legacy(client) => client.billing_rates(model),
            Self::Configured(registry) => registry
                .config
                .reference(model)
                .and_then(|reference| registry.rates.get(reference.model))
                .copied(),
        }
    }

    fn cache_namespace(&self, model: &str) -> String {
        match self {
            Self::Legacy(client) => client.cache_namespace(model),
            // The exact model and adapter version: an adapter's answers are not
            // its model's, and an alias shares the cache of what it points at.
            Self::Configured(registry) => format!(
                "configured/{}/{}",
                registry.fingerprint,
                registry
                    .config
                    .canonical(model)
                    .unwrap_or_else(|| model.to_owned())
            ),
        }
    }
}

impl ProviderRegistry {
    fn new(source: &str, get_env: impl Fn(&str) -> Option<String>) -> Result<Self, ConfigError> {
        if source.len() as u64 > MAX_CONFIG_BYTES {
            return Err(ConfigError("model configuration exceeds 1 MiB".into()));
        }
        let config: Config = toml::from_str(source).map_err(|err| {
            ConfigError(format!("invalid model configuration: {}", err.message()))
        })?;
        if config.version != 1 {
            return Err(ConfigError(
                "unsupported model configuration version; expected 1".into(),
            ));
        }
        if config.providers.is_empty()
            || config.models.is_empty()
            || config.providers.len() > MAX_ENTRIES
            || config.models.len() > MAX_ENTRIES
        {
            return Err(ConfigError(
                "configure between 1 and 256 providers and models".into(),
            ));
        }
        let mut clients = BTreeMap::new();
        let mut credential_fingerprints = BTreeMap::new();
        for (name, provider) in &config.providers {
            validate_identifier(name)?;
            if provider.data_location == DataLocation::Cloud && name.eq_ignore_ascii_case("local") {
                return Err(ConfigError("cloud provider alias cannot be local".into()));
            }
            validate_endpoint(provider)?;
            if provider.kind == ProviderKind::Openrouter
                && (provider.data_location != DataLocation::Cloud || provider.api_key_env.is_none())
            {
                return Err(ConfigError(
                    "OpenRouter requires cloud data_location and api_key_env".into(),
                ));
            }
            let api_key = provider
                .api_key_env
                .as_ref()
                .map(|env| {
                    validate_env_name(env)?;
                    get_env(env)
                        .filter(|value| !value.trim().is_empty())
                        .ok_or_else(|| {
                            ConfigError(format!(
                                "credential environment variable {env} is unset or blank"
                            ))
                        })
                })
                .transpose()?;
            let client = OpenAiClient::new(
                &provider.base_url,
                api_key.clone(),
                provider.kind == ProviderKind::Openrouter,
            )
            .map_err(|_| ConfigError(format!("could not configure provider {name}")))?;
            credential_fingerprints.insert(
                name,
                api_key.map(|key| format!("{:x}", Sha256::digest(key.as_bytes()))),
            );
            clients.insert(name.clone(), client);
        }
        let mut rates = BTreeMap::new();
        for (alias, model) in &config.models {
            validate_identifier(alias)?;
            let provider = config.providers.get(&model.provider).ok_or_else(|| {
                ConfigError(format!("model {alias} references an unknown provider"))
            })?;
            if model.model.trim().is_empty()
                || model.model.len() > 512
                || model.model.chars().any(char::is_control)
            {
                return Err(ConfigError(format!(
                    "model {alias} needs a nonempty model identifier of at most 512 bytes"
                )));
            }
            if model.max_output_tokens == 0 {
                return Err(ConfigError(format!(
                    "model {alias} max_output_tokens must be positive"
                )));
            }
            let openai_compatible = provider.kind == ProviderKind::OpenaiCompatible;
            check_template(
                alias,
                model.chat_template_kwargs.as_ref(),
                openai_compatible,
            )?;
            if !model.adapters.is_empty() && !openai_compatible {
                return Err(ConfigError(format!(
                    "model {alias} has adapters, which only openai_compatible servers apply"
                )));
            }
            let mut lora_ids = std::collections::BTreeSet::new();
            for (name, adapter) in &model.adapters {
                validate_identifier(name)?;
                let label = format!("{alias}:{name}");
                check_template(
                    &label,
                    adapter.chat_template_kwargs.as_ref(),
                    openai_compatible,
                )?;
                let mut versions = std::collections::BTreeSet::new();
                for version in &adapter.versions {
                    if version.version == 0
                        || !versions.insert(version.version)
                        || version.lora_id >= 64
                        || !lora_ids.insert(version.lora_id)
                        || !version.scale.is_finite()
                        || !(0.0..=4.0).contains(&version.scale)
                    {
                        return Err(ConfigError(format!(
                            "adapter {label}: versions need distinct numbers from 1, lora ids below 64 used once per model, and a scale from 0 to 4"
                        )));
                    }
                }
                if !versions.contains(&adapter.current) {
                    return Err(ConfigError(format!(
                        "adapter {label}: current version {} is not one of its versions",
                        adapter.current
                    )));
                }
            }
            let configured_rates = model.pricing.as_ref().map(Pricing::rates).transpose()?;
            let rate = match provider.data_location {
                DataLocation::Local => {
                    if cloud_model_tag(&model.model) {
                        return Err(ConfigError(format!(
                            "model {alias} uses a cloud model tag on a local provider"
                        )));
                    }
                    if configured_rates.is_some_and(|value| value != TokenRates::zero()) {
                        return Err(ConfigError(format!(
                            "local model {alias} token pricing must be zero; account for compute separately"
                        )));
                    }
                    TokenRates::zero()
                }
                DataLocation::Cloud => configured_rates.ok_or_else(|| {
                    ConfigError(format!(
                        "cloud model {alias} requires explicit pricing, including for free tiers"
                    ))
                })?,
            };
            rates.insert(alias.clone(), rate);
        }
        for (alias, target) in &config.aliases {
            validate_identifier(alias)?;
            if config.models.contains_key(alias) {
                return Err(ConfigError(format!(
                    "alias {alias} has the same name as a model"
                )));
            }
            // An alias points at a model reference, never at another alias.
            let ok = !config.aliases.contains_key(target)
                && parse_ref(target)
                    .is_some_and(|reference| config.models.contains_key(reference.model))
                && config.reference(target).is_some();
            if !ok {
                return Err(ConfigError(format!(
                    "alias {alias} must point at a model or model:adapter[@vN], and {target} is not one"
                )));
            }
        }
        for alias in [
            &config.routes.small,
            &config.routes.large,
            &config.routes.frontier,
        ] {
            let Some(reference) = config.reference(alias) else {
                return Err(ConfigError(format!(
                    "route references unknown model alias {alias}"
                )));
            };
            if config.policy == DataPolicy::LocalOnly {
                let model = &config.models[reference.model];
                if config.providers[&model.provider].data_location != DataLocation::Local {
                    return Err(ConfigError(format!(
                        "local_only policy forbids cloud route {alias}"
                    )));
                }
            }
        }
        // Credential digests distinguish API accounts without retaining or
        // publishing plaintext credentials in cache keys. Endpoint/model,
        // pricing, capability and policy changes also invalidate answers.
        let encoded = serde_json::to_vec(&(&config, credential_fingerprints))
            .map_err(|_| ConfigError("could not fingerprint model configuration".into()))?;
        let fingerprint = format!("{:x}", Sha256::digest(encoded));
        Ok(Self {
            config,
            clients,
            rates,
            fingerprint,
        })
    }

    /// What a name serves: the model, its server, and the adapter version a
    /// request switches on, if any.
    fn resolve(&self, name: &str) -> Result<Resolved<'_>, DispatchError> {
        let reference = self
            .config
            .reference(name)
            .ok_or_else(|| DispatchError::Decode(format!("unconfigured model alias {name}")))?;
        // Names borrowed from the registry's own keys, not from the request.
        let (key, model) = self
            .config
            .models
            .get_key_value(reference.model)
            .expect("reference() checked the model exists");
        let provider = &self.config.providers[&model.provider];
        if self.config.policy == DataPolicy::LocalOnly
            && provider.data_location != DataLocation::Local
        {
            return Err(DispatchError::Decode(
                "local_only policy forbids cloud inference".into(),
            ));
        }
        let adapter = reference.adapter.map(|adapter_name| {
            let (adapter_name, adapter) = model
                .adapters
                .get_key_value(adapter_name)
                .expect("reference() checked the adapter exists");
            let wanted = reference.version.unwrap_or(adapter.current);
            let version = adapter
                .versions
                .iter()
                .find(|version| version.version == wanted)
                .expect("reference() checked the version exists");
            (adapter_name.as_str(), adapter, version)
        });
        Ok(Resolved {
            key: key.as_str(),
            model,
            provider,
            adapter,
        })
    }

    fn model_price(&self, alias: &str) -> Result<ModelPrice, DispatchError> {
        let resolved = self.resolve(alias)?;
        let rates = self.rates[resolved.key];
        let small = self
            .config
            .reference(&self.config.routes.small)
            .map(|r| r.model);
        Ok(ModelPrice {
            model: "configured",
            tier: if small == Some(resolved.key) {
                Tier::Small
            } else {
                Tier::Large
            },
            input_per_mtok: rates.input_per_mtok(),
            output_per_mtok: rates.output_per_mtok(),
            min_cacheable_tokens: 0,
            promo: None,
        })
    }

    async fn complete(&self, mut request: ModelRequest) -> Result<ModelResponse, DispatchError> {
        let resolved = self.resolve(&request.model)?;
        let model = resolved.model;
        let has_tools = !request.plan.tools.is_empty()
            || request
                .plan
                .messages
                .iter()
                .flat_map(|message| &message.content)
                .any(|block| !matches!(block, ContentBlock::Text(_)));
        if has_tools && !model.tools {
            return Err(DispatchError::Decode(
                "selected model does not support tools".into(),
            ));
        }
        request.model.clone_from(&model.model);
        request.max_tokens = request.max_tokens.min(model.max_output_tokens);
        let (lora, template) = resolved.deployment();
        let mut response = self.clients[&model.provider]
            .complete_with_deployment(request, &lora, template.as_ref())
            .await?;
        // The server reports the base model either way; the ledger has to say
        // which adapter version answered, or its spend and quality cannot be
        // told apart from the model's.
        if let Some((name, _, version)) = resolved.adapter {
            response.model = format!("{}:{name}@v{}", response.model, version.version);
        }
        response.model = match resolved.provider.data_location {
            DataLocation::Local => format!("local/{}/{}", model.provider, response.model),
            DataLocation::Cloud => format!("{}/{}", model.provider, response.model),
        };
        Ok(response)
    }
}

/// A resolved name.
struct Resolved<'a> {
    key: &'a str,
    model: &'a ModelConfig,
    provider: &'a ProviderConfig,
    adapter: Option<(&'a str, &'a AdapterConfig, &'a AdapterVersion)>,
}

impl Resolved<'_> {
    /// The adapters to switch on and the template settings to send: the
    /// model's, with the adapter's merged over them.
    fn deployment(
        &self,
    ) -> (
        Vec<AdapterUse>,
        Option<serde_json::Map<String, serde_json::Value>>,
    ) {
        let mut template = self.model.chat_template_kwargs.clone().unwrap_or_default();
        let mut lora = Vec::new();
        if let Some((_, adapter, version)) = self.adapter {
            lora.push(AdapterUse {
                id: version.lora_id,
                scale: version.scale,
            });
            for (key, value) in adapter.chat_template_kwargs.iter().flatten() {
                template.insert(key.clone(), value.clone());
            }
        }
        (lora, (!template.is_empty()).then_some(template))
    }
}

fn check_template(
    label: &str,
    kwargs: Option<&serde_json::Map<String, serde_json::Value>>,
    openai_compatible: bool,
) -> Result<(), ConfigError> {
    let Some(kwargs) = kwargs else { return Ok(()) };
    if !openai_compatible {
        return Err(ConfigError(format!(
            "{label} sets chat_template_kwargs, which only openai_compatible servers read"
        )));
    }
    if kwargs.len() > 16
        || kwargs.iter().any(|(key, value)| {
            key.is_empty()
                || key.len() > 64
                || !(value.is_boolean() || value.is_number() || value.is_string())
        })
    {
        return Err(ConfigError(format!(
            "{label} chat_template_kwargs must be at most 16 scalar settings"
        )));
    }
    Ok(())
}

fn validate_identifier(value: &str) -> Result<(), ConfigError> {
    if value.is_empty()
        || value.len() > 128
        || !value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'-' | b'.'))
    {
        return Err(ConfigError("provider/model aliases must be 1–128 ASCII letters, digits, underscores, hyphens or periods".into()));
    }
    Ok(())
}

fn validate_env_name(value: &str) -> Result<(), ConfigError> {
    if value.is_empty()
        || value.len() > 128
        || !value
            .bytes()
            .enumerate()
            .all(|(i, c)| c == b'_' || c.is_ascii_alphabetic() || (i > 0 && c.is_ascii_digit()))
    {
        return Err(ConfigError(
            "api_key_env must name a valid environment variable".into(),
        ));
    }
    Ok(())
}

fn cloud_model_tag(model: &str) -> bool {
    let normalized = model.to_ascii_lowercase();
    normalized.ends_with(":cloud")
        || normalized.ends_with("-cloud")
        || normalized.starts_with("cloud/")
}

fn validate_endpoint(provider: &ProviderConfig) -> Result<(), ConfigError> {
    let url = reqwest::Url::parse(&provider.base_url)
        .map_err(|_| ConfigError("provider base_url must be an absolute HTTP(S) URL".into()))?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(ConfigError(
            "provider base_url must use HTTP(S) without credentials, query or fragment".into(),
        ));
    }
    let host = url.host_str().unwrap_or_default().trim_matches(['[', ']']);
    let ip = host.parse::<IpAddr>().ok();
    let loopback = host.eq_ignore_ascii_case("localhost") || ip.is_some_and(|ip| ip.is_loopback());
    let private = ip.is_some_and(private_address);
    if provider.data_location == DataLocation::Local && !loopback && !private {
        return Err(ConfigError(
            "local provider base_url must use localhost or a numeric loopback/private address"
                .into(),
        ));
    }
    if url.scheme() != "https" && !loopback {
        return Err(ConfigError(
            "provider base_url requires HTTPS except on loopback".into(),
        ));
    }
    Ok(())
}

fn private_address(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => ip.is_private() || ip.is_loopback() || ip.is_link_local(),
        IpAddr::V6(ip) => {
            ip.is_loopback()
                || ip.is_unique_local()
                || ip.is_unicast_link_local()
                || ip
                    .to_ipv4_mapped()
                    .is_some_and(|ip| ip.is_private() || ip.is_loopback() || ip.is_link_local())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        dispatch::ToolCall,
        prompt::{StableContext, Turn, assemble},
    };
    use serde_json::{Value, json};
    use std::sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    };

    fn local_config() -> String {
        r#"
version = 1
policy = "local_only"
[routes]
small = "code"
large = "code"
frontier = "code"
[providers.ollama]
kind = "openai_compatible"
base_url = "http://127.0.0.1:11434/v1"
data_location = "local"
[models.code]
provider = "ollama"
model = "qwen3-coder:30b"
tools = true
max_output_tokens = 4096
"#
        .into()
    }

    fn with_cloud(mut source: String) -> String {
        source.push_str(
            r#"
[providers.remote]
kind = "openrouter"
base_url = "https://openrouter.ai/api/v1"
data_location = "cloud"
api_key_env = "TEST_PROVIDER_KEY"
[models.remote]
provider = "remote"
model = "test/model"
tools = true
max_output_tokens = 1024
[models.remote.pricing]
input_per_mtok = 2.0
output_per_mtok = 8.0
cache_read_per_mtok = 0.5
"#,
        );
        source
    }

    fn load(source: &str) -> Result<ProviderClient, ConfigError> {
        ProviderClient::configured_from(source, |_| Some("test-key".into()))
    }

    fn request(client: &ProviderClient) -> ModelRequest {
        ModelRequest {
            sampling: Default::default(),
            model: "code".into(),
            max_tokens: 8000,
            effort: None,
            plan: assemble(
                &StableContext::default(),
                "hello",
                &client.model_price("code").unwrap(),
            ),
        }
    }

    #[test]
    fn local_models_route_explicitly_and_cost_no_provider_tokens() {
        let client = load(&local_config()).unwrap();
        assert_eq!(
            client.models().unwrap(),
            Models {
                small: "code".into(),
                large: "code".into(),
                frontier: "code".into()
            }
        );
        assert_eq!(client.billing_rates("code"), Some(TokenRates::zero()));
        assert_eq!(client.model_price("code").unwrap().input_per_mtok, 0.0);
        assert!(!client.supports_batch());
        assert!(client.model_price("unconfigured").is_err());
    }

    #[test]
    fn checked_in_local_example_is_usable_without_credentials() {
        let source = include_str!("../../../config/models.local.example.toml");
        let client = ProviderClient::configured_from(source, |_| None).unwrap();
        assert_eq!(client.models().unwrap().large, "local-code");
        assert_eq!(client.billing_rates("local-code"), Some(TokenRates::zero()));
    }

    #[test]
    fn config_rejects_unknown_fields_at_each_level() {
        for source in [
            local_config().replace("version = 1", "version = 1\nunknown = true"),
            local_config().replace("small = \"code\"", "small = \"code\"\nunknown = true"),
            local_config().replace(
                "kind = \"openai_compatible\"",
                "kind = \"openai_compatible\"\nunknown = true",
            ),
            local_config().replace("tools = true", "tools = true\nunknown = true"),
            with_cloud(local_config()).replace(
                "input_per_mtok = 2.0",
                "input_per_mtok = 2.0\nunknown = true",
            ),
        ] {
            assert!(load(&source).is_err(), "accepted unknown field");
        }
    }

    #[test]
    fn config_rejects_bad_references_versions_tokens_prices_and_secrets() {
        for source in [
            local_config().replace("version = 1", "version = 2"),
            local_config().replace("small = \"code\"", "small = \"missing\""),
            local_config().replace("provider = \"ollama\"", "provider = \"missing\""),
            local_config().replace("max_output_tokens = 4096", "max_output_tokens = 0"),
            with_cloud(local_config()).replace("input_per_mtok = 2.0", "input_per_mtok = -1.0"),
            with_cloud(local_config()).replace("input_per_mtok = 2.0", "input_per_mtok = nan"),
            with_cloud(local_config()).replace("input_per_mtok = 2.0", "input_per_mtok = inf"),
            local_config().replace(
                "data_location = \"local\"",
                "data_location = \"local\"\napi_key = \"never-store-this\"",
            ),
        ] {
            assert!(load(&source).is_err());
        }
        assert!(load(&" ".repeat(MAX_CONFIG_BYTES as usize + 1)).is_err());
    }

    #[test]
    fn local_declarations_reject_remote_urls_and_cloud_model_tags() {
        for url in [
            "https://example.com/v1",
            "http://192.168.0.2/v1",
            "http://127.0.0.1/v1?key=x",
            "http://key:secret@127.0.0.1/v1",
            "http://127.0.0.1/v1#fragment",
            "file:///v1",
        ] {
            assert!(
                load(&local_config().replace("http://127.0.0.1:11434/v1", url)).is_err(),
                "accepted {url}"
            );
        }
        for model in ["gpt-oss:120b-cloud", "example:cloud", "cloud/example"] {
            assert!(load(&local_config().replace("qwen3-coder:30b", model)).is_err());
        }
        for url in [
            "http://localhost:11434/v1",
            "http://[::1]:11434/v1",
            "https://192.168.0.2/v1",
            "https://[fd01::1]/v1",
        ] {
            assert!(
                load(&local_config().replace("http://127.0.0.1:11434/v1", url)).is_ok(),
                "rejected {url}"
            );
        }
    }

    #[test]
    fn cloud_requires_explicit_prices_and_a_real_credential_source() {
        let source = with_cloud(local_config());
        assert!(ProviderClient::configured_from(&source, |_| None).is_err());
        assert!(ProviderClient::configured_from(&source, |_| Some("  ".into())).is_err());
        let without_prices = source.split("[models.remote.pricing]").next().unwrap();
        assert!(load(without_prices).is_err());
        let explicit_free = source
            .replace("input_per_mtok = 2.0", "input_per_mtok = 0.0")
            .replace("output_per_mtok = 8.0", "output_per_mtok = 0.0")
            .replace("cache_read_per_mtok = 0.5", "cache_read_per_mtok = 0.0");
        assert!(load(&explicit_free).is_ok());
        assert!(
            load(
                &source
                    .replace("providers.remote", "providers.local")
                    .replace("provider = \"remote\"", "provider = \"local\"")
            )
            .is_err()
        );
        assert!(
            ProviderClient::configured_from(&source, |_| Some("secret\ninvalid-header".into()))
                .is_err()
        );
    }

    #[test]
    fn local_only_rejects_cloud_routes_and_direct_alias_selection() {
        let source = with_cloud(local_config());
        let client = load(&source).unwrap();
        assert!(
            client
                .model_price("remote")
                .unwrap_err()
                .to_string()
                .contains("local_only")
        );
        assert!(load(&source.replace("frontier = \"code\"", "frontier = \"remote\"")).is_err());
        let allowed = load(&source.replace("local_only", "cloud_allowed")).unwrap();
        let rates = allowed.billing_rates("remote").unwrap();
        assert_eq!(rates.input_per_mtok(), 2.0);
        let quote = rates.quote(&farhelm_proto::types::Usage {
            input_tokens: 0,
            output_tokens: 0,
            cache_read_tokens: 1_000_000,
            cache_write_tokens: 1_000_000,
        });
        assert_eq!(quote.total_usd(), 2.5);
    }

    #[test]
    fn cache_identity_tracks_model_runtime_prices_policy_and_credential_identity() {
        let source = with_cloud(local_config());
        let baseline = load(&source).unwrap().cache_namespace("code");
        for updated in [
            source.replace("qwen3-coder:30b", "other:30b"),
            source.replace("11434", "11435"),
            source.replace("tools = true", "tools = false"),
            source.replace("input_per_mtok = 2.0", "input_per_mtok = 3.0"),
            source.replace("local_only", "cloud_allowed"),
        ] {
            assert_ne!(load(&updated).unwrap().cache_namespace("code"), baseline);
        }
        let rotated =
            ProviderClient::configured_from(&source, |_| Some("rotated-key".into())).unwrap();
        assert_ne!(rotated.cache_namespace("code"), baseline);
        assert_eq!(load(&source).unwrap().cache_namespace("code"), baseline);
        assert!(!baseline.contains("test-key"));
    }

    #[tokio::test]
    async fn rejects_cloud_and_unsupported_tools_without_contacting_provider() {
        let calls = Arc::new(AtomicUsize::new(0));
        let count = calls.clone();
        let app = axum::Router::new().route(
            "/v1/chat/completions",
            axum::routing::post(move || {
                count.fetch_add(1, Ordering::SeqCst);
                async { axum::Json(json!({})) }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        let source = with_cloud(local_config())
            .replace("http://127.0.0.1:11434/v1", &format!("http://{address}/v1"))
            .replace(
                "https://openrouter.ai/api/v1",
                &format!("http://{address}/v1"),
            )
            .replace("tools = true", "tools = false");
        let client = load(&source).unwrap();
        let mut cloud = request(&client);
        cloud.model = "remote".into();
        assert!(
            client
                .complete(cloud)
                .await
                .unwrap_err()
                .to_string()
                .contains("local_only")
        );
        let mut tools = request(&client);
        tools
            .plan
            .tools
            .push(json!({"name":"read","input_schema":{"type":"object"}}));
        assert!(
            client
                .complete(tools)
                .await
                .unwrap_err()
                .to_string()
                .contains("does not support tools")
        );
        let mut historic = request(&client);
        let stable = StableContext {
            history: vec![Turn::assistant_with_tools(
                "",
                vec![ToolCall {
                    id: "call_1".into(),
                    name: "read".into(),
                    input: json!({}),
                }],
            )],
            ..StableContext::default()
        };
        historic.plan = assemble(&stable, "continue", &client.model_price("code").unwrap());
        assert!(
            client
                .complete(historic)
                .await
                .unwrap_err()
                .to_string()
                .contains("does not support tools")
        );
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        server.abort();
    }

    #[tokio::test]
    async fn resolves_upstream_model_bounds_output_and_preserves_actual_identity() {
        let captured = Arc::new(Mutex::new(None));
        let saved = captured.clone();
        let app = axum::Router::new().route("/v1/chat/completions", axum::routing::post(move |axum::Json(body): axum::Json<Value>| {
            *saved.lock().unwrap() = Some(body);
            async { axum::Json(json!({"model":"qwen3-coder:30b-pinned", "choices":[{"index":0,"message":{"role":"assistant","content":"hello"},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":3}})) }
        }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        let client = load(
            &local_config().replace("http://127.0.0.1:11434/v1", &format!("http://{address}/v1")),
        )
        .unwrap();
        let response = client.complete(request(&client)).await.unwrap();
        assert_eq!(response.model, "local/ollama/qwen3-coder:30b-pinned");
        assert_eq!(response.usage.input_tokens, 12);
        assert_eq!(response.usage.output_tokens, 3);
        let body = captured.lock().unwrap().take().unwrap();
        assert_eq!(body["model"], "qwen3-coder:30b");
        assert_eq!(body["max_tokens"], 4096);
        server.abort();
    }

    /// A model with one adapter in two versions, and aliases for each form,
    /// served by the mock at `address`.
    fn with_adapters(address: &str) -> String {
        format!(
            r#"
version = 1
policy = "local_only"
[routes]
small = "work"
large = "work"
frontier = "work"
[providers.engine]
kind = "openai_compatible"
base_url = "http://{address}/v1"
data_location = "local"
[models.base-model]
provider = "engine"
model = "base-model"
tools = true
max_output_tokens = 512
card = {{ owner = "Example Labs" }}
[models.base-model.adapters.short]
current = 2
purpose = "brief answers"
chat_template_kwargs = {{ enable_thinking = false }}
versions = [
  {{ version = 1, lora_id = 0 }},
  {{ version = 2, lora_id = 1, scale = 0.5, evaluation = "beat v1" }},
]
[aliases]
work = "base-model"
quick = "base-model:short"
pinned = "base-model:short@v1"
# The shared `request` helper prices its request as `code`.
code = "base-model"
"#
        )
    }

    async fn mock() -> (
        std::net::SocketAddr,
        Arc<Mutex<Vec<Value>>>,
        tokio::task::JoinHandle<()>,
    ) {
        let captured = Arc::new(Mutex::new(Vec::new()));
        let saved = captured.clone();
        let app = axum::Router::new().route("/v1/chat/completions", axum::routing::post(move |axum::Json(body): axum::Json<Value>| {
            saved.lock().unwrap().push(body);
            async { axum::Json(json!({"model":"base-model", "choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":1}})) }
        }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        (address, captured, server)
    }

    #[tokio::test]
    async fn a_model_and_its_adapter_are_chosen_by_name_and_recorded_exactly() {
        let (address, captured, server) = mock().await;
        let client = load(&with_adapters(&address.to_string())).unwrap();
        let ask = |name: &str| {
            let mut asked = request(&client);
            asked.model = name.into();
            asked
        };

        // `model:adapter` serves the current version, with the adapter's
        // template settings merged over the caller's.
        let mut current = ask("base-model:short");
        current.sampling.reasoning_effort = Some("low".into());
        let response = client.complete(current).await.unwrap();
        assert_eq!(response.model, "local/engine/base-model:short@v2");
        // An alias, and a pinned version.
        assert_eq!(
            client.complete(ask("quick")).await.unwrap().model,
            "local/engine/base-model:short@v2"
        );
        assert_eq!(
            client.complete(ask("pinned")).await.unwrap().model,
            "local/engine/base-model:short@v1"
        );
        assert_eq!(
            client
                .complete(ask("base-model:short@v1"))
                .await
                .unwrap()
                .model,
            "local/engine/base-model:short@v1"
        );
        // The model alone uses no adapter and no template.
        assert_eq!(
            client.complete(ask("work")).await.unwrap().model,
            "local/engine/base-model"
        );

        let bodies = captured.lock().unwrap();
        assert_eq!(bodies[0]["model"], "base-model");
        assert_eq!(bodies[0]["lora"], json!([{ "id": 1, "scale": 0.5 }]));
        assert_eq!(
            bodies[0]["chat_template_kwargs"],
            json!({ "enable_thinking": false, "reasoning_effort": "low" })
        );
        assert_eq!(bodies[2]["lora"], json!([{ "id": 0, "scale": 1.0 }]));
        assert!(bodies[4].get("lora").is_none() && bodies[4].get("chat_template_kwargs").is_none());
        drop(bodies);

        // An alias shares the cache of exactly what it points at; versions do not.
        assert_eq!(
            client.cache_namespace("quick"),
            client.cache_namespace("base-model:short@v2")
        );
        assert_ne!(
            client.cache_namespace("quick"),
            client.cache_namespace("pinned")
        );
        assert_ne!(
            client.cache_namespace("quick"),
            client.cache_namespace("work")
        );

        assert_eq!(
            client.canonical("quick").as_deref(),
            Some("base-model:short@v2")
        );
        assert_eq!(
            client.alias_target("quick").as_deref(),
            Some("base-model:short")
        );
        assert!(client.declares("base-model:short@v1") && !client.declares("base-model:short@v3"));
        assert!(!client.declares("base-model:long") && !client.declares("other-model"));
        assert!(
            client
                .model_aliases()
                .contains(&"base-model:short".to_owned())
        );
        server.abort();
    }

    #[test]
    fn summaries_list_each_models_adapters_and_aliases() {
        let client = load(&with_adapters("127.0.0.1:9")).unwrap();
        let summaries = client.summaries();
        let model = &summaries[0];
        assert_eq!(model.name, "base-model");
        assert_eq!(model.routes, ["small", "large", "frontier"]);
        assert_eq!(model.aliases, ["code", "work"]);
        assert_eq!(model.adapters[0].name, "short");
        assert_eq!(model.adapters[0].config.current, 2);
        assert_eq!(model.adapters[0].aliases, ["pinned", "quick"]);
    }

    #[test]
    fn adapters_aliases_and_cards_are_held_to_their_rules() {
        let good = with_adapters("127.0.0.1:9");
        assert!(load(&good).is_ok());
        let broken = |from: &str, to: &str| {
            assert!(good.contains(from), "fixture lacks {from:?}");
            load(&good.replace(from, to)).is_err()
        };
        // Aliases point at a real model reference, never another alias, and
        // never take a model's name.
        assert!(broken("quick = \"base-model:short\"", "quick = \"work\""));
        assert!(broken(
            "quick = \"base-model:short\"",
            "quick = \"base-model:long\""
        ));
        assert!(broken(
            "pinned = \"base-model:short@v1\"",
            "pinned = \"base-model:short@v3\""
        ));
        assert!(broken(
            "work = \"base-model\"",
            "work = \"base-model\"\nbase-model = \"base-model\""
        ));
        // Versions: current must exist; lora ids once per model; sane scale.
        assert!(broken("current = 2", "current = 3"));
        assert!(broken(
            "version = 2, lora_id = 1",
            "version = 2, lora_id = 0"
        ));
        assert!(broken("scale = 0.5", "scale = 9.0"));
        assert!(broken(
            "version = 1, lora_id = 0",
            "version = 0, lora_id = 0"
        ));
        // Unknown fields and nested template values are refused.
        assert!(broken(
            "purpose = \"brief answers\"",
            "purpose = \"brief answers\"\ncolour = \"red\""
        ));
        assert!(broken(
            "{ enable_thinking = false }",
            "{ nested = { a = 1 } }"
        ));
        assert!(broken(
            "card = { owner = \"Example Labs\" }",
            "card = { kind = \"base\" }"
        ));
        // Only openai_compatible servers apply adapters.
        let cloud = with_cloud(local_config()).replace(
            "max_output_tokens = 1024\n",
            "max_output_tokens = 1024\n[models.remote.adapters.x]\ncurrent = 1\nversions = [{ version = 1, lora_id = 0 }]\n",
        );
        assert!(load(&cloud).is_err());
    }

    #[test]
    fn a_name_parses_into_model_adapter_and_version() {
        assert_eq!(
            parse_ref("m"),
            Some(ModelRef {
                model: "m",
                adapter: None,
                version: None
            })
        );
        assert_eq!(
            parse_ref("m:a"),
            Some(ModelRef {
                model: "m",
                adapter: Some("a"),
                version: None
            })
        );
        assert_eq!(
            parse_ref("qwen3.5-4b:conscious@v2"),
            Some(ModelRef {
                model: "qwen3.5-4b",
                adapter: Some("conscious"),
                version: Some(2)
            })
        );
        for bad in ["", ":a", "m:", "m:a@2", "m:a@v0", "m:a@vx"] {
            assert_eq!(parse_ref(bad), None, "{bad:?}");
        }
    }
}
