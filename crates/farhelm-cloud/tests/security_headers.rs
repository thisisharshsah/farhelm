//! The security headers, as a browser receives them from the service the
//! binary runs: the web app, its deep links, the API and the connector's
//! sign-in page.

use std::sync::Arc;

use base64::Engine as _;
use farhelm_cloud::store::CloudStore;
use farhelm_cloud::{CloudConfig, CloudState, billing::Billing};
use farhelm_crypto::token::TokenSigner;
use reqwest::header::HeaderMap;
use sha2::Digest as _;

const RELAY: &str = "wss://relay.example.test";

/// Serves the whole app, with a one-page web build, at a loopback address.
async fn serve(tag: &str, public_url: &str) -> String {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());

    let app_dir = std::env::temp_dir().join(format!(
        "farhelm-cloud-headers-{tag}-{}",
        std::process::id()
    ));
    std::fs::create_dir_all(&app_dir).unwrap();
    std::fs::write(
        app_dir.join("index.html"),
        "<!doctype html><title>Farhelm</title><div id=\"root\"></div>",
    )
    .unwrap();

    let state = Arc::new(CloudState {
        store: CloudStore::open_in_memory().unwrap(),
        signer: TokenSigner::generate(),
        billing: Billing::Disabled,
        config: CloudConfig {
            relay_url: RELAY.into(),
            public_url: public_url.into(),
        },
        throttle: Default::default(),
    });
    let router = farhelm_cloud::app(state, Some(app_dir.to_str().unwrap()));
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    base
}

async fn get(url: &str) -> (u16, HeaderMap, String) {
    let response = reqwest::get(url).await.unwrap();
    let status = response.status().as_u16();
    let headers = response.headers().clone();
    (status, headers, response.text().await.unwrap())
}

fn header<'a>(headers: &'a HeaderMap, name: &str) -> &'a str {
    headers
        .get(name)
        .map(|value| value.to_str().unwrap())
        .unwrap_or_else(|| panic!("no {name} header"))
}

#[tokio::test]
async fn the_app_its_deep_links_and_the_api_carry_the_headers() {
    let base = serve("https", "https://cloud.example.test").await;

    for path in ["/", "/runners/some-machine"] {
        let (status, headers, body) = get(&format!("{base}{path}")).await;
        assert_eq!(status, 200, "{path}");
        assert!(body.contains("id=\"root\""), "{path} is the app");
        let policy = header(&headers, "content-security-policy");
        assert!(policy.contains("script-src 'self';"), "{policy}");
        assert!(
            policy.contains(
                "connect-src 'self' wss://relay.example.test https://relay.example.test;"
            ),
            "{policy}"
        );
        assert!(policy.contains("frame-ancestors 'none'"), "{policy}");
        assert!(!policy.contains("unsafe"), "{policy}");
        assert_eq!(header(&headers, "x-content-type-options"), "nosniff");
        assert_eq!(header(&headers, "x-frame-options"), "DENY");
        assert_eq!(header(&headers, "referrer-policy"), "no-referrer");
        assert_eq!(
            header(&headers, "strict-transport-security"),
            "max-age=31536000; includeSubDomains"
        );
        // The app shell may be cached; only answers with secrets are not.
        assert_ne!(
            headers
                .get("cache-control")
                .map(|value| value.to_str().unwrap()),
            Some("no-store")
        );
    }

    let (status, headers, _) = get(&format!("{base}/v1/health")).await;
    assert_eq!(status, 200);
    assert_eq!(header(&headers, "cache-control"), "no-store");
    assert!(header(&headers, "content-security-policy").contains("frame-ancestors 'none'"));
}

#[tokio::test]
async fn a_deployment_on_plain_http_sends_no_hsts() {
    let base = serve("http", "http://127.0.0.1:7844").await;
    let (status, headers, _) = get(&format!("{base}/")).await;
    assert_eq!(status, 200);
    assert!(headers.get("strict-transport-security").is_none());
    assert!(headers.get("content-security-policy").is_some());
}

#[tokio::test]
async fn the_connector_sign_in_page_may_style_itself_and_nothing_else_inline() {
    let base = serve("connector", "https://cloud.example.test").await;
    // No parameters: the page explains it cannot connect, in the same frame
    // and style as the sign-in form.
    let (status, headers, body) = get(&format!("{base}/oauth/authorize")).await;
    assert_eq!(status, 400);
    let css = body
        .split_once("<style>")
        .and_then(|(_, rest)| rest.split_once("</style>"))
        .map(|(css, _)| css)
        .expect("the page has its inline style");
    let hash =
        base64::engine::general_purpose::STANDARD.encode(sha2::Sha256::digest(css.as_bytes()));
    let policy = header(&headers, "content-security-policy");
    assert!(
        policy.contains(&format!("style-src 'self' 'sha256-{hash}';")),
        "{policy}"
    );
    assert!(!policy.contains("unsafe-inline"), "{policy}");
    assert_eq!(header(&headers, "cache-control"), "no-store");
}
