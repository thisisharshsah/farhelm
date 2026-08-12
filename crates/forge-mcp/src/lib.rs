//! RelayForge as a remote MCP server.
//!
//! This is the "custom connector" surface: Claude — running on Anthropic's
//! infrastructure, not on your machine — calls in over HTTPS and gets a set of
//! tools it can use during a conversation.
//!
//! # Which way the arrows point
//!
//! Worth stating plainly, because it is the thing people expect to work and it
//! does not: a connector lets **Claude call your tools**. It does not give this
//! system access to a model, and it does not route Claude's own reasoning
//! through the cost gateway. When someone chats in the Claude app, inference
//! happens on Anthropic's side and this server never sees it.
//!
//! What that buys is still the thing worth having. The conversation runs on a
//! Claude subscription rather than metered API tokens, and the few calls that
//! genuinely need the API can be made *through* a tool that puts them through
//! `forge-gateway`'s eight stages. Cheap reasoning, metered work minimised.
//!
//! ```text
//!   You ──▶ Claude (subscription)  ──MCP──▶ RelayForge tools
//!                                             └── complete() ──▶ cost gateway ──▶ API
//! ```
//!
//! # Two servers, one authorization server
//!
//! [`forge-cloud`] hosts the OAuth authorization server *and* a fleet-level tool
//! set; each runner hosts a second MCP server with the tools that need to read
//! session content. They are separate because the alternative is worse: a
//! fleet-wide server that could read sessions would need a device key, and the
//! control plane holding one would end the property that a compromise there
//! costs you access rather than content.
//!
//! Both accept tokens minted by the one authorization server, so a person signs
//! in once, with the account they already have.

pub mod oauth;
pub mod protocol;
pub mod tools;

/// What this server calls itself in the `initialize` handshake.
pub const SERVER_NAME: &str = "relayforge";
pub const SERVER_VERSION: &str = env!("CARGO_PKG_VERSION");

/// The audience an MCP access token carries.
///
/// Distinct from the `api` and `relay` audiences so a token good for the
/// connector cannot be replayed against the control plane's own API — Claude is
/// a third party, and a token it holds should reach exactly the tool surface it
/// was granted and nothing else.
pub const MCP_AUDIENCE: forge_crypto::token::Audience = forge_crypto::token::Audience::Mcp;
