pub mod app_server;
pub mod auth;
pub mod config;
pub mod proxy;

use std::sync::Arc;

use axum::{
    Router,
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::get,
};
use serde::Serialize;
use tokio::sync::{Mutex, watch};
use tower_http::{
    services::{ServeDir, ServeFile},
    trace::{DefaultOnResponse, TraceLayer},
};
use tracing::{Level, info_span};

pub use app_server::{CodexProcess, ensure_codex_available};
pub use config::{Config, ConfigError};

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<Config>,
    pub codex_process: Arc<Mutex<Option<CodexProcess>>>,
    shutdown: watch::Sender<bool>,
}

impl AppState {
    pub fn new(config: Config) -> Self {
        let (shutdown, _) = watch::channel(false);
        Self {
            config: Arc::new(config),
            codex_process: Arc::new(Mutex::new(None)),
            shutdown,
        }
    }

    pub fn begin_shutdown(&self) {
        self.shutdown.send_replace(true);
    }

    pub(crate) fn subscribe_shutdown(&self) -> watch::Receiver<bool> {
        self.shutdown.subscribe()
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
    if app_server::codex_is_ready(state.config.codex_socket_addr).await {
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
