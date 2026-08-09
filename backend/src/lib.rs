pub mod app_server;
pub mod auth;
pub mod config;
pub mod proxy;
pub mod ssh;

use std::sync::Arc;

use axum::{
    Router,
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde::Serialize;
use tokio::sync::{Mutex, RwLock, watch};
use tower_http::{
    services::{ServeDir, ServeFile},
    trace::{DefaultOnResponse, TraceLayer},
};
use tracing::{Level, info_span};
use url::Url;

pub use app_server::{CodexProcess, ensure_codex_available};
pub use config::{Config, ConfigError};

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<Config>,
    pub codex_process: Arc<Mutex<Option<CodexProcess>>>,
    pub ssh_session: Arc<Mutex<Option<ssh::SshSession>>>,
    pub upstream: Arc<RwLock<UpstreamTarget>>,
    shutdown: watch::Sender<bool>,
}

#[derive(Clone)]
pub struct UpstreamTarget {
    pub url: Url,
    pub socket_addr: std::net::SocketAddr,
    pub mode: &'static str,
}

impl AppState {
    pub fn new(config: Config) -> Self {
        let (shutdown, _) = watch::channel(false);
        let upstream = UpstreamTarget {
            url: config.codex_url.clone(),
            socket_addr: config.codex_socket_addr,
            mode: "local",
        };
        Self {
            config: Arc::new(config),
            codex_process: Arc::new(Mutex::new(None)),
            ssh_session: Arc::new(Mutex::new(None)),
            upstream: Arc::new(RwLock::new(upstream)),
            shutdown,
        }
    }

    pub fn begin_shutdown(&self) {
        self.shutdown.send_replace(true);
    }

    pub(crate) fn subscribe_shutdown(&self) -> watch::Receiver<bool> {
        self.shutdown.subscribe()
    }

    pub fn local_upstream(&self) -> UpstreamTarget {
        UpstreamTarget {
            url: self.config.codex_url.clone(),
            socket_addr: self.config.codex_socket_addr,
            mode: "local",
        }
    }

    pub async fn active_upstream(&self) -> UpstreamTarget {
        self.upstream.read().await.clone()
    }
}

pub fn router(state: AppState) -> Router {
    let index_file = state.config.frontend_dir.join("index.html");
    let static_service = ServeDir::new(state.config.frontend_dir.clone())
        .not_found_service(ServeFile::new(index_file));

    Router::new()
        .route("/health", get(health))
        .route("/healthz", get(health))
        .route("/ready", get(ready))
        .route("/readyz", get(ready))
        .route("/ws", get(proxy::websocket_handler))
        .route("/api/ssh/connect", post(ssh::connect_handler))
        .route("/api/ssh/disconnect", post(ssh::disconnect_handler))
        .route("/api/ssh/status", get(ssh::status_handler))
        .fallback_service(static_service)
        .layer(
            TraceLayer::new_for_http()
                .make_span_with(|request: &axum::http::Request<_>| {
                    // Use only the path: legacy clients may carry the gateway token in the query.
                    info_span!(
                        "http_request",
                        method = %request.method(),
                        path = %request.uri().path()
                    )
                })
                .on_response(DefaultOnResponse::new().level(Level::INFO)),
        )
        .with_state(state)
}

#[derive(Serialize)]
struct StatusBody<'a> {
    status: &'a str,
}

async fn health() -> impl IntoResponse {
    axum::Json(StatusBody { status: "ok" })
}

async fn ready(State(state): State<AppState>) -> Response {
    let upstream = state.active_upstream().await;
    if app_server::codex_is_ready(upstream.socket_addr).await {
        (StatusCode::OK, axum::Json(StatusBody { status: "ready" })).into_response()
    } else {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            axum::Json(StatusBody {
                status: "not_ready",
            }),
        )
            .into_response()
    }
}
