//! The runner's API answers this machine's own clients and nothing else: not
//! a tunnel's traffic, not a page that rebinds its name to loopback, and not
//! another web page. Health stays open, as it does with the local token.

use std::sync::Arc;
use std::time::Duration;

use farhelm_crypto::Identity;
use farhelm_runner::api::{self, LocalAuth};
use farhelm_sqlite::SqliteStore;
use reqwest::{Client, StatusCode};

async fn start() -> (String, tokio::task::JoinHandle<()>) {
    let state = farhelm_runner::test_support::state(
        SqliteStore::open_in_memory().unwrap(),
        Arc::new(Identity::generate()),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let router = api::router_with_auth(state, LocalAuth::open());
    let task = tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    (url, task)
}

async fn status(request: reqwest::RequestBuilder) -> StatusCode {
    request.send().await.unwrap().status()
}

#[tokio::test]
async fn the_api_answers_this_machine_and_nothing_else() {
    let (url, server) = start().await;
    let http = Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .unwrap();
    let fleet = format!("{url}/v1/fleet");
    let port = url.rsplit(':').next().unwrap().to_owned();

    // This machine, by address and by name.
    assert_eq!(status(http.get(&fleet)).await, StatusCode::OK);
    let by_name = http.get(&fleet).header("host", format!("localhost:{port}"));
    assert_eq!(status(by_name).await, StatusCode::OK);

    // A public hostname a tunnel routes to this port.
    let tunnelled = http.get(&fleet).header("host", "farhelm-mac.aurovie.com");
    assert_eq!(status(tunnelled).await, StatusCode::FORBIDDEN);

    // Had the tunnel rewritten the Host, its own headers still give it away.
    let cloudflare = http.get(&fleet).header("cf-connecting-ip", "203.0.113.9");
    assert_eq!(status(cloudflare).await, StatusCode::FORBIDDEN);
    let proxied = http
        .get(&fleet)
        .header("x-forwarded-for", "203.0.113.9, 127.0.0.1");
    assert_eq!(status(proxied).await, StatusCode::FORBIDDEN);

    // A dev server proxying on this machine is still this machine.
    let dev_proxy = http.get(&fleet).header("x-forwarded-for", "127.0.0.1");
    assert_eq!(status(dev_proxy).await, StatusCode::OK);

    // A page that rebinds its own name to loopback keeps its own Host.
    let rebound = http
        .get(&fleet)
        .header("host", format!("attacker.example:{port}"));
    assert_eq!(status(rebound).await, StatusCode::FORBIDDEN);

    // Another web page, even one that only fires a request it cannot read.
    let cross_site = http
        .post(format!("{url}/v1/sessions/nobody/stop"))
        .header("origin", "https://attacker.example");
    assert_eq!(status(cross_site).await, StatusCode::FORBIDDEN);

    // The runner's own page and the dev server are let through.
    let own_page = http.get(&fleet).header("origin", url.as_str());
    assert_eq!(status(own_page).await, StatusCode::OK);
    let dev_server = http.get(&fleet).header("origin", "http://localhost:5173");
    assert_eq!(status(dev_server).await, StatusCode::OK);

    // Health answers anyone: it says nothing.
    let health = http
        .get(format!("{url}/v1/health"))
        .header("host", "farhelm-mac.aurovie.com");
    assert_eq!(status(health).await, StatusCode::OK);

    server.abort();
}
