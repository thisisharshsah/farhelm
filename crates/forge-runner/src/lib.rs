//! The RelayForge runner, as a library.
//!
//! The binary is a thin CLI over this. Splitting them lets the integration tests
//! drive the real relay link and command layer in-process — the alternative was
//! spawning the daemon and poking it over HTTP, which tests the transport rather
//! than the behaviour.

pub mod api;
pub mod cloud;
pub mod commands;
pub mod hook;
pub mod hook_cli;
pub mod mcp;
pub mod messages;
pub mod pty;
pub mod relay;
pub mod seed;
pub mod service;
pub mod session;
pub mod state;
pub mod task;
pub mod terminal;
pub mod test_support;
pub mod views;
pub mod watcher;
