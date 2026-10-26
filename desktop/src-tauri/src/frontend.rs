//! Serve Tauri's compiled frontend on the runner's loopback origin.
//!
//! No runtime filesystem lookup: a desktop launched outside the checkout must
//! serve exactly the assets that were built into that executable.

use std::borrow::Cow;
use std::sync::Arc;

use axum::Router;
use axum::extract::{Path, State};
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use tauri::utils::assets::{AssetKey, AssetsIter, CspHash};
use tauri::utils::mime_type::MimeType;
use tauri::{Assets, Wry};

/// Tauri and Axum share one provider without copying the whole frontend.
#[derive(Clone)]
pub struct FrontendAssets(Arc<dyn Assets<Wry>>);

impl FrontendAssets {
    pub fn new(assets: Box<dyn Assets<Wry>>) -> Self {
        Self(Arc::from(assets))
    }

    fn response(&self, path: &str) -> Response {
        // `Path` already percent-decodes the request. Reject traversal before
        // AssetKey's normalization, including Windows separators on any host.
        if path.starts_with('/')
            || path.contains(['\\', '\0'])
            || path.split('/').any(|part| part == "." || part == "..")
        {
            return StatusCode::BAD_REQUEST.into_response();
        }
        if path == "v1" || path.starts_with("v1/") {
            return StatusCode::NOT_FOUND.into_response();
        }

        let key = if path.is_empty() { "index.html" } else { path };
        let found = self.0.get(&AssetKey::from(key));
        let (key, bytes) = match found {
            Some(bytes) => (key, bytes),
            // Navigation can fall back to the app shell; missing scripts,
            // styles and API routes must not receive an HTML success response.
            None if path != "assets"
                && !path.starts_with("assets/")
                && !path.rsplit('/').next().unwrap_or_default().contains('.') =>
            {
                let Some(bytes) = self.0.get(&AssetKey::from("index.html")) else {
                    return StatusCode::NOT_FOUND.into_response();
                };
                ("index.html", bytes)
            }
            None => return StatusCode::NOT_FOUND.into_response(),
        };

        let mime = if key.ends_with(".webmanifest") {
            "application/manifest+json".to_owned()
        } else if key.ends_with(".map") {
            "application/json".to_owned()
        } else {
            MimeType::parse_with_fallback(&bytes, key, MimeType::OctetStream)
        };
        (
            [
                (header::CONTENT_TYPE, mime.as_str()),
                (header::CACHE_CONTROL, "no-cache"),
                (header::X_CONTENT_TYPE_OPTIONS, "nosniff"),
            ],
            bytes.into_owned(),
        )
            .into_response()
    }
}

impl Assets<Wry> for FrontendAssets {
    fn setup(&self, app: &tauri::App<Wry>) {
        self.0.setup(app);
    }

    fn get(&self, key: &AssetKey) -> Option<Cow<'_, [u8]>> {
        self.0.get(key)
    }

    fn iter(&self) -> Box<AssetsIter<'_>> {
        self.0.iter()
    }

    fn csp_hashes(&self, path: &AssetKey) -> Box<dyn Iterator<Item = CspHash<'_>> + '_> {
        self.0.csp_hashes(path)
    }
}

pub fn router(assets: FrontendAssets) -> Router {
    Router::new()
        .route("/", get(index))
        .route("/{*path}", get(asset))
        .with_state(assets)
}

async fn index(State(assets): State<FrontendAssets>) -> Response {
    assets.response("")
}

async fn asset(State(assets): State<FrontendAssets>, Path(path): Path<String>) -> Response {
    assets.response(&path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn embedded() -> FrontendAssets {
        FrontendAssets::new(crate::desktop_context().assets)
    }

    #[test]
    fn lookup_rejects_traversal_and_does_not_mask_missing_assets_or_api_routes() {
        let assets = embedded();
        for path in [
            "../index.html",
            "assets/../index.html",
            "/v1/missing",
            "..\\index.html",
            "\0",
        ] {
            assert_eq!(
                assets.response(path).status(),
                StatusCode::BAD_REQUEST,
                "{path}"
            );
        }
        for path in [
            "v1",
            "v1/missing",
            "assets",
            "assets/missing.js",
            "assets/missing",
            "missing.css",
        ] {
            assert_eq!(
                assets.response(path).status(),
                StatusCode::NOT_FOUND,
                "{path}"
            );
        }
        assert_eq!(assets.response("workspace/tasks").status(), StatusCode::OK);
        assert_eq!(
            assets.response("workspace/tasks").headers()[header::CONTENT_TYPE],
            "text/html"
        );
    }

    #[test]
    fn embedded_frontend_and_api_work_outside_the_checkout() {
        const CHILD: &str = "FARHELM_EMBEDDED_FRONTEND_TEST_CHILD";
        if std::env::var_os(CHILD).is_some() {
            assert!(!std::path::Path::new("web/dist").exists());
            tokio::runtime::Runtime::new()
                .unwrap()
                .block_on(check_embedded_http());
            return;
        }

        // A subprocess avoids changing the process-global CWD while unrelated
        // tests are running. This launches the test harness, never a GUI app.
        let directory = std::env::temp_dir().join(format!("farhelm-assets-{}", std::process::id()));
        std::fs::create_dir(&directory).unwrap();
        let result = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "frontend::tests::embedded_frontend_and_api_work_outside_the_checkout",
                "--nocapture",
            ])
            .env(CHILD, "1")
            .current_dir(&directory)
            .output();
        std::fs::remove_dir(&directory).unwrap();
        let output = result.unwrap();
        assert!(
            output.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    async fn check_embedded_http() {
        let assets = embedded();
        let expected_index = assets
            .get(&AssetKey::from("index.html"))
            .unwrap()
            .into_owned();
        assert!(
            String::from_utf8_lossy(&expected_index).contains("<div id=\"root\"></div>"),
            "build the real web app before desktop tests"
        );
        let keys: Vec<String> = assets.iter().map(|(key, _)| key.into_owned()).collect();
        let state = farhelm_runner::state::AppState::build(
            farhelm_sqlite::SqliteStore::open_in_memory().unwrap(),
            |_| None,
            Arc::new(farhelm_crypto::Identity::generate()),
            None,
        );
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(
            axum::serve(listener, crate::desktop_app(state, assets.clone())).into_future(),
        );
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(5))
            .build()
            .unwrap();
        let base = format!("http://{address}");
        let index = client.get(&base).send().await.unwrap();
        assert_eq!(index.status(), StatusCode::OK);
        assert_eq!(index.headers()[header::CONTENT_TYPE], "text/html");
        assert_eq!(index.headers()[header::X_CONTENT_TYPE_OPTIONS], "nosniff");
        assert_eq!(index.bytes().await.unwrap().as_ref(), expected_index);
        for (extension, mime) in [(".js", "text/javascript"), (".css", "text/css")] {
            let key = keys
                .iter()
                .find(|key| key.starts_with("/assets/") && key.ends_with(extension))
                .unwrap();
            let expected = assets.get(&AssetKey::from(key)).unwrap();
            let response = client
                .get(format!("{base}{key}?cache=1"))
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            assert_eq!(response.headers()[header::CONTENT_TYPE], mime);
            assert_eq!(response.bytes().await.unwrap().as_ref(), expected.as_ref());
        }
        let worker = client.get(format!("{base}/sw.js")).send().await.unwrap();
        assert_eq!(worker.status(), StatusCode::OK);
        assert_eq!(worker.headers()[header::CONTENT_TYPE], "text/javascript");
        assert_eq!(worker.headers()[header::CACHE_CONTROL], "no-cache");
        for (path, mime) in [
            ("/manifest.webmanifest", "application/manifest+json"),
            ("/icon.svg", "image/svg+xml"),
        ] {
            let response = client.get(format!("{base}{path}")).send().await.unwrap();
            assert_eq!(response.status(), StatusCode::OK, "{path}");
            assert_eq!(response.headers()[header::CONTENT_TYPE], mime, "{path}");
        }
        let head = client.head(&base).send().await.unwrap();
        assert_eq!(head.status(), StatusCode::OK);
        assert!(head.bytes().await.unwrap().is_empty());
        for path in ["/v1/fleet", "/v1/desktop/status"] {
            let response = client.get(format!("{base}{path}")).send().await.unwrap();
            assert_eq!(response.status(), StatusCode::OK, "{path}");
            assert_eq!(response.headers()[header::CONTENT_TYPE], "application/json");
        }
        for (path, status) in [
            ("/v1", StatusCode::NOT_FOUND),
            ("/v1/missing", StatusCode::NOT_FOUND),
            ("/assets", StatusCode::NOT_FOUND),
            ("/assets/missing.js", StatusCode::NOT_FOUND),
            ("/assets/%2e%2e%2findex.html", StatusCode::BAD_REQUEST),
            ("/assets/%5cindex.html", StatusCode::BAD_REQUEST),
            ("/%2fv1/missing", StatusCode::BAD_REQUEST),
        ] {
            let response = client.get(format!("{base}{path}")).send().await.unwrap();
            assert_eq!(response.status(), status, "{path}");
        }
        let navigation = client
            .get(format!("{base}/workspace/tasks"))
            .send()
            .await
            .unwrap();
        assert_eq!(navigation.status(), StatusCode::OK);
        assert_eq!(navigation.bytes().await.unwrap().as_ref(), expected_index);
        let post = client.post(&base).send().await.unwrap();
        assert_eq!(post.status(), StatusCode::METHOD_NOT_ALLOWED);
        server.abort();
    }
}
