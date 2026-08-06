//! The price table and cost computation (pipeline stage 8).
//!
//! Rates are dollars per million tokens, from the Anthropic pricing table as of
//! 2026-07-30. Cache and batch rates are *derived* from the base input rate
//! rather than typed out per model, because the multipliers are uniform across
//! the family — one fewer place for a transcription error.
//!
//! `cost_usd` is computed once, at ledger-write time, and never recomputed.
//! That is what makes `usage_event` append-only: editing this table changes
//! what future calls cost, never what past calls cost.

use std::fmt;

use crate::types::{Tier, Usage};

/// Cache writes bill above the base input rate; reads bill far below it.
pub const CACHE_WRITE_5M_MULTIPLIER: f64 = 1.25;
pub const CACHE_WRITE_1H_MULTIPLIER: f64 = 2.0;
pub const CACHE_READ_MULTIPLIER: f64 = 0.1;
/// The Batch API discount (C6). Stacks with caching.
pub const BATCH_MULTIPLIER: f64 = 0.5;

/// Models whose id starts with this prefix are self-hosted (vLLM/Ollama) and
/// bill at zero — §7's "my own model" small tier, where cost is electricity.
pub const LOCAL_MODEL_PREFIX: &str = "local/";

/// Time-boxed promotional pricing. Applied when the event timestamp is before
/// `until_ms`, so a ledger row written during the promo keeps the promo rate
/// forever even after it lapses.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Promo {
    pub input_per_mtok: f64,
    pub output_per_mtok: f64,
    /// Exclusive upper bound, unix ms.
    pub until_ms: i64,
}

/// Which cache TTL a call requested. Only affects the write rate; reads are the
/// same either way.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum CacheTtl {
    #[default]
    FiveMinutes,
    OneHour,
}

impl CacheTtl {
    const fn write_multiplier(self) -> f64 {
        match self {
            CacheTtl::FiveMinutes => CACHE_WRITE_5M_MULTIPLIER,
            CacheTtl::OneHour => CACHE_WRITE_1H_MULTIPLIER,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ModelPrice {
    pub model: &'static str,
    /// Which tier the router treats this model as by default.
    pub tier: Tier,
    pub input_per_mtok: f64,
    pub output_per_mtok: f64,
    /// Prompts shorter than this silently do not cache — the cache-shaped
    /// prefix (M1) must clear it or the whole mechanism is a no-op.
    pub min_cacheable_tokens: u32,
    pub promo: Option<Promo>,
}

impl ModelPrice {
    /// Base input/output rates in effect at `at_ms`.
    pub fn rates_at(&self, at_ms: i64) -> (f64, f64) {
        match self.promo {
            Some(promo) if at_ms < promo.until_ms => (promo.input_per_mtok, promo.output_per_mtok),
            _ => (self.input_per_mtok, self.output_per_mtok),
        }
    }
}

/// 2026-09-01T00:00:00Z — when Claude Sonnet 5's introductory pricing lapses.
const SONNET_5_PROMO_UNTIL_MS: i64 = 1_788_220_800_000;

/// The price table. Add a model here and the router, ledger, and dashboard all
/// pick it up.
pub const PRICES: &[ModelPrice] = &[
    ModelPrice {
        model: "claude-opus-5",
        tier: Tier::Large,
        input_per_mtok: 5.00,
        output_per_mtok: 25.00,
        min_cacheable_tokens: 512,
        promo: None,
    },
    ModelPrice {
        model: "claude-opus-4-8",
        tier: Tier::Large,
        input_per_mtok: 5.00,
        output_per_mtok: 25.00,
        min_cacheable_tokens: 1024,
        promo: None,
    },
    ModelPrice {
        model: "claude-sonnet-5",
        tier: Tier::Large,
        input_per_mtok: 3.00,
        output_per_mtok: 15.00,
        min_cacheable_tokens: 1024,
        promo: Some(Promo {
            input_per_mtok: 2.00,
            output_per_mtok: 10.00,
            until_ms: SONNET_5_PROMO_UNTIL_MS,
        }),
    },
    ModelPrice {
        model: "claude-haiku-4-5",
        tier: Tier::Small,
        input_per_mtok: 1.00,
        output_per_mtok: 5.00,
        min_cacheable_tokens: 4096,
        promo: None,
    },
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnknownModel(pub String);

impl fmt::Display for UnknownModel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "no price-table entry for model {:?} — add one to forge_core::price::PRICES \
             or prefix the id with {LOCAL_MODEL_PREFIX:?} if it is self-hosted",
            self.0
        )
    }
}

impl std::error::Error for UnknownModel {}

/// Zero-cost entry used for self-hosted endpoints.
fn local_price(model: &str) -> ModelPrice {
    // `model` is borrowed only to confirm the prefix; the entry itself is static.
    debug_assert!(model.starts_with(LOCAL_MODEL_PREFIX));
    ModelPrice {
        model: "local",
        tier: Tier::Small,
        input_per_mtok: 0.0,
        output_per_mtok: 0.0,
        min_cacheable_tokens: 0,
        promo: None,
    }
}

/// Look up a model's price entry.
pub fn price_of(model: &str) -> Result<ModelPrice, UnknownModel> {
    if model.starts_with(LOCAL_MODEL_PREFIX) {
        return Ok(local_price(model));
    }
    PRICES
        .iter()
        .find(|price| price.model == model)
        .copied()
        .ok_or_else(|| UnknownModel(model.to_owned()))
}

/// Everything that varies per call but is not token counts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QuoteContext {
    /// Ledger timestamp, unix ms. Selects promotional rates.
    pub at_ms: i64,
    pub cache_ttl: CacheTtl,
    /// Whether the call went through the Batch API (50% off).
    pub batch: bool,
}

impl QuoteContext {
    /// Interactive dispatch with the default 5-minute cache TTL.
    pub const fn interactive(at_ms: i64) -> Self {
        Self {
            at_ms,
            cache_ttl: CacheTtl::FiveMinutes,
            batch: false,
        }
    }

    pub const fn batched(at_ms: i64) -> Self {
        Self {
            at_ms,
            cache_ttl: CacheTtl::FiveMinutes,
            batch: true,
        }
    }
}

/// A cost broken out by billing line, so the dashboard can show *where* the
/// money went rather than one opaque number.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Quote {
    pub input_usd: f64,
    pub output_usd: f64,
    pub cache_write_usd: f64,
    pub cache_read_usd: f64,
}

impl Quote {
    pub fn total_usd(&self) -> f64 {
        self.input_usd + self.output_usd + self.cache_write_usd + self.cache_read_usd
    }
}

const fn dispatch_multiplier(ctx: QuoteContext) -> f64 {
    if ctx.batch { BATCH_MULTIPLIER } else { 1.0 }
}

fn per_token(rate_per_mtok: f64, tokens: u32) -> f64 {
    rate_per_mtok * f64::from(tokens) / 1_000_000.0
}

/// Price one model call.
pub fn quote(model: &str, usage: &Usage, ctx: QuoteContext) -> Result<Quote, UnknownModel> {
    let price = price_of(model)?;
    Ok(quote_with(&price, usage, ctx))
}

/// Price one model call against an already-resolved table entry.
pub fn quote_with(price: &ModelPrice, usage: &Usage, ctx: QuoteContext) -> Quote {
    let (input_rate, output_rate) = price.rates_at(ctx.at_ms);
    let dispatch = dispatch_multiplier(ctx);

    Quote {
        input_usd: per_token(input_rate * dispatch, usage.input_tokens),
        output_usd: per_token(output_rate * dispatch, usage.output_tokens),
        cache_write_usd: per_token(
            input_rate * ctx.cache_ttl.write_multiplier() * dispatch,
            usage.cache_write_tokens,
        ),
        cache_read_usd: per_token(
            input_rate * CACHE_READ_MULTIPLIER * dispatch,
            usage.cache_read_tokens,
        ),
    }
}

/// What `usage` would have cost with no caching at all: every cache-read and
/// cache-write token billed as plain input. Pair with [`quote`] to report the
/// savings M1 actually delivered.
pub fn uncached_cost_usd(
    model: &str,
    usage: &Usage,
    ctx: QuoteContext,
) -> Result<f64, UnknownModel> {
    let price = price_of(model)?;
    let (input_rate, output_rate) = price.rates_at(ctx.at_ms);
    let dispatch = dispatch_multiplier(ctx);
    let input_tokens = u64::from(usage.input_tokens)
        + u64::from(usage.cache_write_tokens)
        + u64::from(usage.cache_read_tokens);

    Ok(input_rate * dispatch * input_tokens as f64 / 1_000_000.0
        + per_token(output_rate * dispatch, usage.output_tokens))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 2026-07-30T00:00:00Z
    const NOW_MS: i64 = 1_785_369_600_000;

    fn approx(actual: f64, expected: f64) {
        assert!(
            (actual - expected).abs() < 1e-9,
            "expected {expected}, got {actual}"
        );
    }

    #[test]
    fn every_table_entry_is_reachable_by_its_own_id() {
        for price in PRICES {
            assert_eq!(price_of(price.model).unwrap().model, price.model);
        }
    }

    #[test]
    fn an_unpriced_model_is_an_error_not_a_free_call() {
        let err = quote(
            "gpt-hypothetical",
            &Usage::default(),
            QuoteContext::interactive(NOW_MS),
        )
        .unwrap_err();
        assert_eq!(err.0, "gpt-hypothetical");
    }

    #[test]
    fn self_hosted_models_bill_at_zero() {
        let usage = Usage {
            input_tokens: 1_000_000,
            output_tokens: 1_000_000,
            ..Usage::default()
        };
        let quote = quote(
            "local/qwen3-coder",
            &usage,
            QuoteContext::interactive(NOW_MS),
        )
        .unwrap();
        approx(quote.total_usd(), 0.0);
    }

    #[test]
    fn a_million_input_tokens_costs_exactly_the_listed_rate() {
        let usage = Usage {
            input_tokens: 1_000_000,
            ..Usage::default()
        };
        let quote = quote("claude-opus-5", &usage, QuoteContext::interactive(NOW_MS)).unwrap();
        approx(quote.input_usd, 5.00);
        approx(quote.total_usd(), 5.00);
    }

    #[test]
    fn cache_reads_bill_at_a_tenth_of_input() {
        let read_only = Usage {
            cache_read_tokens: 1_000_000,
            ..Usage::default()
        };
        let quote = quote(
            "claude-opus-5",
            &read_only,
            QuoteContext::interactive(NOW_MS),
        )
        .unwrap();
        approx(quote.cache_read_usd, 0.50);
    }

    #[test]
    fn a_one_hour_cache_write_costs_more_than_a_five_minute_one() {
        let usage = Usage {
            cache_write_tokens: 1_000_000,
            ..Usage::default()
        };
        let five_min = quote("claude-opus-5", &usage, QuoteContext::interactive(NOW_MS)).unwrap();
        let one_hour = quote_with(
            &price_of("claude-opus-5").unwrap(),
            &usage,
            QuoteContext {
                cache_ttl: CacheTtl::OneHour,
                ..QuoteContext::interactive(NOW_MS)
            },
        );
        approx(five_min.cache_write_usd, 6.25);
        approx(one_hour.cache_write_usd, 10.00);
    }

    #[test]
    fn batch_dispatch_halves_every_line_item() {
        let usage = Usage {
            input_tokens: 1_000_000,
            output_tokens: 1_000_000,
            cache_write_tokens: 1_000_000,
            cache_read_tokens: 1_000_000,
        };
        let live = quote("claude-opus-5", &usage, QuoteContext::interactive(NOW_MS)).unwrap();
        let batched = quote("claude-opus-5", &usage, QuoteContext::batched(NOW_MS)).unwrap();
        approx(batched.total_usd(), live.total_usd() * BATCH_MULTIPLIER);
    }

    #[test]
    fn sonnet_5_intro_pricing_applies_now_and_lapses_on_schedule() {
        let usage = Usage {
            input_tokens: 1_000_000,
            output_tokens: 1_000_000,
            ..Usage::default()
        };
        let during = quote("claude-sonnet-5", &usage, QuoteContext::interactive(NOW_MS)).unwrap();
        approx(during.total_usd(), 2.00 + 10.00);

        let after = quote(
            "claude-sonnet-5",
            &usage,
            QuoteContext::interactive(SONNET_5_PROMO_UNTIL_MS),
        )
        .unwrap();
        approx(after.total_usd(), 3.00 + 15.00);
    }

    #[test]
    fn caching_is_cheaper_than_not_caching_for_the_same_token_mix() {
        // The M1 claim: a turn whose context is served from cache bills far less
        // than the same turn with every token sent fresh.
        let usage = Usage {
            input_tokens: 2_000,
            output_tokens: 500,
            cache_write_tokens: 0,
            cache_read_tokens: 40_000,
        };
        let ctx = QuoteContext::interactive(NOW_MS);
        let cached = quote("claude-opus-5", &usage, ctx).unwrap().total_usd();
        let uncached = uncached_cost_usd("claude-opus-5", &usage, ctx).unwrap();
        assert!(
            cached < uncached * 0.4,
            "cached {cached} should be far below uncached {uncached}"
        );
    }
}
