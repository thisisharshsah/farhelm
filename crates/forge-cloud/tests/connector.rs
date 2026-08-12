//! The connector flow, driven the way Claude drives it.
//!
//! Every step here is one Claude actually performs when someone pastes the URL
//! into "Add custom connector" and leaves both Advanced fields blank: discover,
//! register, authorize, exchange, then speak MCP. A unit test can check each
//! piece; only this can check that the chain *joins up* — and a broken link
//! anywhere in it shows up to a user as a connector that silently will not
//! connect.

use std::sync::Arc;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use forge_cloud::store::CloudStore;
use forge_cloud::{CloudConfig, CloudState, api, billing::Billing, mcp};
use forge_crypto::token::TokenSigner;
use serde_json::{Value, json};

struct World {
    base: String,
    client: reqwest::Client,
}

async fn spawn() -> World {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let addr = listener.local_addr().unwrap();
    let base = format!("http://{addr}");

    let state = Arc::new(CloudState {
        store: CloudStore::open_in_memory().unwrap(),
        signer: TokenSigner::generate(),
        billing: Billing::Disabled,
        config: CloudConfig {
            relay_url: "ws://127.0.0.1:7843".into(),
            public_url: base.clone(),
        },
    });

    let router = api::router(Arc::clone(&state)).merge(mcp::router(state));
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });

    World {
        base,
        // Redirects must NOT be followed: the authorization code arrives in the
        // `Location` header, and a client that chases it loses the code.
        client: reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .unwrap(),
    }
}

impl World {
    async fn get_json(&self, path: &str) -> Value {
        self.client
            .get(format!("{}{path}", self.base))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap()
    }

    async fn sign_up(&self, email: &str) {
        let response = self
            .client
            .post(format!("{}/v1/auth/signup", self.base))
            .json(&json!({ "email": email, "password": "correct horse battery", "name": "Harsh" }))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), 200);
    }

    /// A JSON-RPC call against the MCP endpoint.
    async fn rpc(&self, token: &str, method: &str, params: Value) -> Value {
        let response = self
            .client
            .post(format!("{}/mcp", self.base))
            .bearer_auth(token)
            .json(&json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params }))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), 200, "{method} was not answered");
        response.json().await.unwrap()
    }
}

/// A PKCE pair, computed the way a client computes it.
fn pkce() -> (String, String) {
    use sha2::{Digest as _, Sha256};
    let verifier = "verifier-".to_owned() + &"x".repeat(48);
    let challenge = B64.encode(Sha256::digest(verifier.as_bytes()));
    (verifier, challenge)
}

/// Everything from discovery to a usable access token.
async fn connect(world: &World) -> String {
    // 1. Unauthenticated call → 401 pointing at the resource metadata.
    let refused = world
        .client
        .post(format!("{}/mcp", world.base))
        .json(&json!({"jsonrpc": "2.0", "id": 1, "method": "initialize"}))
        .send()
        .await
        .unwrap();
    assert_eq!(refused.status().as_u16(), 401);
    let challenge_header = refused
        .headers()
        .get("www-authenticate")
        .expect("a 401 must say where to authenticate")
        .to_str()
        .unwrap()
        .to_owned();
    assert!(challenge_header.contains("resource_metadata="));

    // 2 & 3. Follow the chain to the authorization server's metadata.
    let resource = world
        .get_json("/.well-known/oauth-protected-resource")
        .await;
    let issuer = resource["authorization_servers"][0].as_str().unwrap();
    assert_eq!(issuer, world.base);
    let server = world
        .get_json("/.well-known/oauth-authorization-server")
        .await;

    // 4. Register — this is what makes the Advanced fields optional.
    let registration = world
        .client
        .post(server["registration_endpoint"].as_str().unwrap())
        .json(&json!({
            "client_name": "Claude",
            "redirect_uris": ["https://claude.ai/api/mcp/auth_callback"],
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(registration.status().as_u16(), 201);
    let client: Value = registration.json().await.unwrap();
    let client_id = client["client_id"].as_str().unwrap().to_owned();
    assert_eq!(client["token_endpoint_auth_method"], "none");

    // 5. Sign in and consent → a redirect carrying the code.
    let (verifier, challenge) = pkce();
    let consent = world
        .client
        .post(format!("{}/oauth/authorize", world.base))
        .form(&[
            ("email", "harsh@example.com"),
            ("password", "correct horse battery"),
            ("client_id", &client_id),
            ("redirect_uri", "https://claude.ai/api/mcp/auth_callback"),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
            ("state", "opaque-state"),
            ("resource", ""),
        ])
        .send()
        .await
        .unwrap();

    assert_eq!(consent.status().as_u16(), 303, "consent should redirect");
    let location = consent
        .headers()
        .get("location")
        .unwrap()
        .to_str()
        .unwrap()
        .to_owned();
    assert!(
        location.contains("state=opaque-state"),
        "state must echo back"
    );
    let code = location
        .split("code=")
        .nth(1)
        .unwrap()
        .split('&')
        .next()
        .unwrap()
        .to_owned();

    // 6. Exchange it.
    let token: Value = world
        .client
        .post(format!("{}/oauth/token", world.base))
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", &code),
            ("redirect_uri", "https://claude.ai/api/mcp/auth_callback"),
            ("client_id", &client_id),
            ("code_verifier", &verifier),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    assert_eq!(token["token_type"], "Bearer");
    assert!(token["refresh_token"].is_string());
    token["access_token"].as_str().unwrap().to_owned()
}

#[tokio::test]
async fn claude_can_discover_register_and_connect_with_nothing_pasted_by_hand() {
    let world = spawn().await;
    world.sign_up("harsh@example.com").await;
    let access = connect(&world).await;

    // The handshake.
    let initialized = world
        .rpc(
            &access,
            "initialize",
            json!({"protocolVersion": "2025-06-18"}),
        )
        .await;
    assert_eq!(initialized["result"]["protocolVersion"], "2025-06-18");
    assert_eq!(initialized["result"]["serverInfo"]["name"], "relayforge");

    // The tools.
    let listed = world.rpc(&access, "tools/list", json!({})).await;
    let tools = listed["result"]["tools"].as_array().unwrap();
    assert!(tools.iter().any(|tool| tool["name"] == "list_machines"));
    // Every tool must carry a schema Claude can call against.
    for tool in tools {
        assert_eq!(tool["inputSchema"]["type"], "object", "{tool}");
    }

    // A real call.
    let called = world
        .rpc(&access, "tools/call", json!({"name": "list_machines"}))
        .await;
    assert_eq!(called["result"]["isError"], false);
    assert_eq!(called["result"]["content"][0]["type"], "text");
}

#[tokio::test]
async fn a_notification_gets_no_body() {
    // Answering `notifications/initialized` breaks the connection at exactly
    // the moment it is being established.
    let world = spawn().await;
    world.sign_up("harsh@example.com").await;
    let access = connect(&world).await;

    let response = world
        .client
        .post(format!("{}/mcp", world.base))
        .bearer_auth(&access)
        .json(&json!({"jsonrpc": "2.0", "method": "notifications/initialized"}))
        .send()
        .await
        .unwrap();

    assert_eq!(response.status().as_u16(), 202);
    assert!(response.text().await.unwrap().is_empty());
}

#[tokio::test]
async fn a_code_cannot_be_redeemed_without_its_verifier() {
    // The property PKCE exists for, over real HTTP: intercepting the redirect
    // is not enough.
    let world = spawn().await;
    world.sign_up("harsh@example.com").await;

    let registration: Value = world
        .client
        .post(format!("{}/oauth/register", world.base))
        .json(&json!({"client_name": "Claude", "redirect_uris": ["https://claude.ai/cb"]}))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let client_id = registration["client_id"].as_str().unwrap();

    let (_verifier, challenge) = pkce();
    let consent = world
        .client
        .post(format!("{}/oauth/authorize", world.base))
        .form(&[
            ("email", "harsh@example.com"),
            ("password", "correct horse battery"),
            ("client_id", client_id),
            ("redirect_uri", "https://claude.ai/cb"),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
            ("state", ""),
            ("resource", ""),
        ])
        .send()
        .await
        .unwrap();
    let location = consent.headers().get("location").unwrap().to_str().unwrap();
    let code = location
        .split("code=")
        .nth(1)
        .unwrap()
        .split('&')
        .next()
        .unwrap();

    let stolen: Value = world
        .client
        .post(format!("{}/oauth/token", world.base))
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", "https://claude.ai/cb"),
            ("client_id", client_id),
            ("code_verifier", &"wrong-".repeat(9)),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    assert_eq!(stolen["error"], "invalid_grant");
}

#[tokio::test]
async fn a_code_works_once() {
    let world = spawn().await;
    world.sign_up("harsh@example.com").await;

    let registration: Value = world
        .client
        .post(format!("{}/oauth/register", world.base))
        .json(&json!({"client_name": "Claude", "redirect_uris": ["https://claude.ai/cb"]}))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let client_id = registration["client_id"].as_str().unwrap();
    let (verifier, challenge) = pkce();

    let consent = world
        .client
        .post(format!("{}/oauth/authorize", world.base))
        .form(&[
            ("email", "harsh@example.com"),
            ("password", "correct horse battery"),
            ("client_id", client_id),
            ("redirect_uri", "https://claude.ai/cb"),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
            ("state", ""),
            ("resource", ""),
        ])
        .send()
        .await
        .unwrap();
    let location = consent.headers().get("location").unwrap().to_str().unwrap();
    let code = location
        .split("code=")
        .nth(1)
        .unwrap()
        .split('&')
        .next()
        .unwrap();

    let exchange = |code: String| {
        let client = world.client.clone();
        let base = world.base.clone();
        let client_id = client_id.to_owned();
        let verifier = verifier.clone();
        async move {
            client
                .post(format!("{base}/oauth/token"))
                .form(&[
                    ("grant_type", "authorization_code"),
                    ("code", &code),
                    ("redirect_uri", "https://claude.ai/cb"),
                    ("client_id", &client_id),
                    ("code_verifier", &verifier),
                ])
                .send()
                .await
                .unwrap()
                .json::<Value>()
                .await
                .unwrap()
        }
    };

    assert!(exchange(code.to_owned()).await["access_token"].is_string());
    // Replaying it is how a leaked code becomes a second session.
    assert_eq!(exchange(code.to_owned()).await["error"], "invalid_grant");
}

#[tokio::test]
async fn a_code_is_never_sent_to_an_unregistered_redirect() {
    // Without this, a client id — which is public — would be enough to aim a
    // code at a server the attacker controls.
    let world = spawn().await;
    world.sign_up("harsh@example.com").await;

    let registration: Value = world
        .client
        .post(format!("{}/oauth/register", world.base))
        .json(&json!({"client_name": "Claude", "redirect_uris": ["https://claude.ai/cb"]}))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let (_, challenge) = pkce();

    let response = world
        .client
        .post(format!("{}/oauth/authorize", world.base))
        .form(&[
            ("email", "harsh@example.com"),
            ("password", "correct horse battery"),
            ("client_id", registration["client_id"].as_str().unwrap()),
            ("redirect_uri", "https://evil.example.com/steal"),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
            ("state", ""),
            ("resource", ""),
        ])
        .send()
        .await
        .unwrap();

    assert_eq!(response.status().as_u16(), 400);
    assert!(response.headers().get("location").is_none());
}

#[tokio::test]
async fn a_connector_token_cannot_be_replayed_against_the_control_plane_api() {
    // Claude is a third party. Its token must reach the tool surface it was
    // granted and nothing else — which is why `mcp` is its own audience.
    let world = spawn().await;
    world.sign_up("harsh@example.com").await;
    let access = connect(&world).await;

    let response = world
        .client
        .get(format!("{}/v1/workspace", world.base))
        .bearer_auth(&access)
        .send()
        .await
        .unwrap();

    assert_eq!(response.status().as_u16(), 401);
}

#[tokio::test]
async fn one_workspace_cannot_see_anothers_machines_through_the_connector() {
    // The tenancy boundary again, this time with a third party holding the
    // token. The org comes from the token, never from the tool arguments.
    let world = spawn().await;
    world.sign_up("harsh@example.com").await;
    world.sign_up("someone@example.com").await;

    let access = connect(&world).await;
    let called = world
        .rpc(&access, "tools/call", json!({"name": "list_machines"}))
        .await;

    let text = called["result"]["content"][0]["text"].as_str().unwrap();
    let machines: Value = serde_json::from_str(text).unwrap();
    assert_eq!(machines.as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn an_unknown_method_is_a_json_rpc_error_not_a_500() {
    let world = spawn().await;
    world.sign_up("harsh@example.com").await;
    let access = connect(&world).await;

    let response = world.rpc(&access, "resources/list", json!({})).await;
    assert_eq!(response["error"]["code"], -32601);
    assert!(response.get("result").is_none());
}

#[tokio::test]
async fn a_failing_tool_is_reported_inside_the_result() {
    // Not as a JSON-RPC error: the call worked, the tool said no, and Claude
    // needs to read why so it can try something else.
    let world = spawn().await;
    world.sign_up("harsh@example.com").await;
    let access = connect(&world).await;

    let called = world
        .rpc(
            &access,
            "tools/call",
            json!({"name": "start_task", "arguments": {
                "machine": "nonexistent", "repo_path": "/srv/x", "prompt": "do a thing"
            }}),
        )
        .await;

    assert!(called.get("error").is_none(), "should not be an RPC error");
    assert_eq!(called["result"]["isError"], true);
    assert!(
        called["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("nonexistent")
    );
}

#[tokio::test]
async fn a_refresh_token_mints_a_fresh_access_token() {
    let world = spawn().await;
    world.sign_up("harsh@example.com").await;

    let registration: Value = world
        .client
        .post(format!("{}/oauth/register", world.base))
        .json(&json!({"client_name": "Claude", "redirect_uris": ["https://claude.ai/cb"]}))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let client_id = registration["client_id"].as_str().unwrap();
    let (verifier, challenge) = pkce();

    let consent = world
        .client
        .post(format!("{}/oauth/authorize", world.base))
        .form(&[
            ("email", "harsh@example.com"),
            ("password", "correct horse battery"),
            ("client_id", client_id),
            ("redirect_uri", "https://claude.ai/cb"),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
            ("state", ""),
            ("resource", ""),
        ])
        .send()
        .await
        .unwrap();
    let location = consent.headers().get("location").unwrap().to_str().unwrap();
    let code = location
        .split("code=")
        .nth(1)
        .unwrap()
        .split('&')
        .next()
        .unwrap();

    let first: Value = world
        .client
        .post(format!("{}/oauth/token", world.base))
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", "https://claude.ai/cb"),
            ("client_id", client_id),
            ("code_verifier", &verifier),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    let refreshed: Value = world
        .client
        .post(format!("{}/oauth/token", world.base))
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", first["refresh_token"].as_str().unwrap()),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    assert!(refreshed["access_token"].is_string());
    // The refresh token is deliberately not rotated: a connector may hold
    // several access tokens at once.
    assert_eq!(refreshed["refresh_token"], first["refresh_token"]);
}
