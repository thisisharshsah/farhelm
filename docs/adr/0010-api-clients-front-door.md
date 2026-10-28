# 0010: API clients through the runner's front door

Status: implemented, 2026-10-28. User direction: other projects on this
machine that call models directly (gpt-oss through a private gateway) should
go through Farhelm, so usage can be seen and optimized in one place.

## Context

Several projects (everest, lacuna, career) reached gpt-oss-20b through
`local-assistant`, a separate Python gateway with its own keys, ledger and
limits. Two gateways meant two records of usage and two sets of limits, and
none of Farhelm's routing, caching or specialists applied to those calls.

## Decision

The runner serves a front door on its existing loopback listener:

- `POST /p/<client>/v1/chat/completions` (OpenAI style, with tools and a
  synthetic stream), `POST /p/<client>/v1/messages` (Anthropic style) and
  `GET /p/<client>/v1/models`. The paths match `local-assistant`'s, so a
  project moves by changing the port.
- An API client is an entry in `clients.toml` beside the runner's state:
  a name, the SHA-256 of its key, an optional default model, an optional list
  of models it may use and an optional daily token limit (UTC day, all
  endpoints, from the ledger). `farhelm clients add|rotate|remove|list`
  manages it; a key is printed once and never stored. The file is mode 0600
  and read at start.
- Every call goes through the gateway: `local_only`, routing, the response
  cache and the ledger. A call is recorded under the session
  `client-<name>`, and its cache entries carry the scope `client:<name>`, so
  one client never receives another's cached answer. A client may name a
  registry model (`CompleteRequest::model`); the registry still refuses
  undeclared and, under `local_only`, cloud models.
- A wrong key and an unknown client get the same 401, so names cannot be
  probed. A declared model the client may not use is a 403, not a silent
  substitution. An undeclared or empty name uses the client's default model,
  as the previous gateway did, and the response names what ran.

"Client" rather than "project", because Farhelm's projects are workspaces
with repositories, conversations and tasks.

## Consequences

- One ledger and one set of limits for every local model call on the
  machine.
- The runner becomes a dependency of those projects. A service restart
  leaves the engine's servers running and the next runner adopts them, so
  a restart costs about a second (measured: a call answered 1.3 s after
  the restart began) rather than a model reload. A client should still
  retry a refused connection.
- A client's `temperature`, `top_p`, `max_tokens` (lowered, never raised)
  and `reasoning_effort` (top-level or in `chat_template_kwargs`) reach the
  model, and a client can have a `default_effort`; the moved projects keep
  gpt-oss at the `low` effort their previous gateway gave them. All of it is
  part of the cache key. `response_format` is not applied (the previous
  gateway did not apply it either; the clients put their schema in the
  prompt). `seed` is ignored, streaming is one delta as on `/v1/messages`,
  and images and audio are refused.
- `local-assistant` can retire once its projects have moved and its models
  run on the engine (gpt-oss-20b and the C2 adapter already do).
- everest, career and lacuna were moved on 2026-10-28: their `.env` files
  (and career's `.env.live`) point at the front door, with the previous
  files kept in `~/.farhelm/backups/env-before-front-door/`.
- Not built: per-client budgets in dollars (local tokens cost nothing in the
  ledger), a web page for clients, and limits that change without a restart.
