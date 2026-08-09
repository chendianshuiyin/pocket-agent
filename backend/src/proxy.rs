use axum::{
    extract::{Query, State, WebSocketUpgrade, ws},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use tokio_tungstenite::tungstenite;
use tracing::{debug, warn};

use crate::{AppState, auth};

#[derive(Deserialize)]
pub struct AuthQuery {
    token: Option<String>,
}

pub async fn websocket_handler(
    State(state): State<AppState>,
    Query(query): Query<AuthQuery>,
    headers: HeaderMap,
    upgrade: WebSocketUpgrade,
) -> Response {
    if !auth::authorized(&headers, query.token.as_deref(), &state.config.token) {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }

    let upstream = match tokio_tungstenite::connect_async(state.config.codex_url.as_str()).await {
        Ok((stream, _response)) => stream,
        Err(error) => {
            warn!(%error, "failed to connect to Codex app-server");
            return (StatusCode::BAD_GATEWAY, "Codex app-server is unavailable").into_response();
        }
    };

    let shutdown = state.subscribe_shutdown();
    upgrade.on_upgrade(move |client| relay(client, upstream, shutdown))
}

async fn relay(
    client: ws::WebSocket,
    upstream: tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
    mut shutdown: tokio::sync::watch::Receiver<bool>,
) {
    let (mut client_tx, mut client_rx) = client.split();
    let (mut upstream_tx, mut upstream_rx) = upstream.split();

    loop {
        tokio::select! {
            changed = shutdown.changed() => {
                if changed.is_ok() && *shutdown.borrow() {
                    let _ = upstream_tx.send(tungstenite::Message::Close(None)).await;
                    let _ = client_tx.send(ws::Message::Close(None)).await;
                }
                break;
            }
            message = client_rx.next() => {
                let Some(message) = message else {
                    break;
                };
                match message
                    .map_err(RelayError::ClientRead)
                    .map(to_upstream)
                {
                    Ok(message) => {
                        if let Err(error) = upstream_tx.send(message).await {
                            debug!(%error, "client-to-Codex relay ended");
                            break;
                        }
                    }
                    Err(error) => {
                        debug!(%error, "client-to-Codex relay ended");
                        break;
                    }
                }
            }
            message = upstream_rx.next() => {
                let Some(message) = message else {
                    break;
                };
                match message.map_err(RelayError::UpstreamRead) {
                    Ok(message) => {
                        if let Some(message) = to_client(message) {
                            if let Err(error) = client_tx.send(message).await {
                                debug!(%error, "Codex-to-client relay ended");
                                break;
                            }
                        }
                    }
                    Err(error) => {
                        debug!(%error, "Codex-to-client relay ended");
                        break;
                    }
                }
            }
        }
    }
}

fn to_upstream(message: ws::Message) -> tungstenite::Message {
    match message {
        ws::Message::Text(text) => tungstenite::Message::Text(text.as_str().into()),
        ws::Message::Binary(data) => tungstenite::Message::Binary(data),
        ws::Message::Ping(data) => tungstenite::Message::Ping(data),
        ws::Message::Pong(data) => tungstenite::Message::Pong(data),
        ws::Message::Close(frame) => {
            tungstenite::Message::Close(frame.map(|frame| tungstenite::protocol::CloseFrame {
                code: frame.code.into(),
                reason: frame.reason.as_str().into(),
            }))
        }
    }
}

fn to_client(message: tungstenite::Message) -> Option<ws::Message> {
    match message {
        tungstenite::Message::Text(text) => Some(ws::Message::Text(text.as_str().into())),
        tungstenite::Message::Binary(data) => Some(ws::Message::Binary(data)),
        tungstenite::Message::Ping(data) => Some(ws::Message::Ping(data)),
        tungstenite::Message::Pong(data) => Some(ws::Message::Pong(data)),
        tungstenite::Message::Close(frame) => {
            Some(ws::Message::Close(frame.map(|frame| ws::CloseFrame {
                code: frame.code.into(),
                reason: frame.reason.to_string().into(),
            })))
        }
        tungstenite::Message::Frame(_) => None,
    }
}

#[derive(Debug, thiserror::Error)]
enum RelayError {
    #[error("client read failed: {0}")]
    ClientRead(axum::Error),
    #[error("upstream read failed: {0}")]
    UpstreamRead(tungstenite::Error),
}
