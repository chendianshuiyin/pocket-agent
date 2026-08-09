use std::{net::SocketAddr, path::PathBuf, time::Duration};

use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use futures_util::{SinkExt, StreamExt};
use http_body_util::BodyExt;
use pocket_agent_gateway::{AppState, Config, router};
use tempfile::TempDir;
use tokio::{net::TcpListener, task::JoinHandle};
use tokio_tungstenite::{accept_async, connect_async, tungstenite::Message};
use tower::ServiceExt;
use url::Url;

struct TestServers {
    gateway_addr: SocketAddr,
    state: AppState,
    _upstream_task: JoinHandle<()>,
    _gateway_task: JoinHandle<()>,
    _frontend: TempDir,
}

async fn start_servers() -> TestServers {
    let upstream_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let upstream_addr = upstream_listener.local_addr().unwrap();
    let upstream_task = tokio::spawn(async move {
        loop {
            let (stream, _) = upstream_listener.accept().await.unwrap();
            tokio::spawn(async move {
                let mut websocket = accept_async(stream).await.unwrap();
                while let Some(message) = websocket.next().await {
                    let message = message.unwrap();
                    if message.is_text() || message.is_binary() {
                        websocket.send(message).await.unwrap();
                    } else if message.is_close() {
                        break;
                    }
                }
            });
        }
    });

    let frontend = tempfile::tempdir().unwrap();
    std::fs::write(frontend.path().join("index.html"), "pocket-agent-ui").unwrap();
    let config = Config {
        bind_addr: "127.0.0.1:0".parse().unwrap(),
        token: "test-secret".to_owned(),
        codex_url: Url::parse(&format!("ws://{upstream_addr}")).unwrap(),
        codex_socket_addr: upstream_addr,
        auto_start_codex: false,
        codex_bin: PathBuf::from("codex"),
        codex_start_timeout: Duration::from_secs(1),
        frontend_dir: frontend.path().to_owned(),
    };

    let gateway_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let gateway_addr = gateway_listener.local_addr().unwrap();
    let state = AppState::new(config);
    let server_state = state.clone();
    let gateway_task = tokio::spawn(async move {
        axum::serve(gateway_listener, router(server_state))
            .await
            .unwrap();
    });

    TestServers {
        gateway_addr,
        state,
        _upstream_task: upstream_task,
        _gateway_task: gateway_task,
        _frontend: frontend,
    }
}

#[tokio::test]
async fn health_and_static_site_are_served() {
    let frontend = tempfile::tempdir().unwrap();
    std::fs::write(frontend.path().join("index.html"), "pocket-agent-ui").unwrap();
    let state = AppState::new(Config {
        bind_addr: "127.0.0.1:0".parse().unwrap(),
        token: "test-secret".to_owned(),
        codex_url: Url::parse("ws://127.0.0.1:9").unwrap(),
        codex_socket_addr: "127.0.0.1:9".parse().unwrap(),
        auto_start_codex: false,
        codex_bin: PathBuf::from("codex"),
        codex_start_timeout: Duration::from_secs(1),
        frontend_dir: frontend.path().to_owned(),
    });

    let health = router(state.clone())
        .oneshot(Request::get("/health").body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(health.status(), StatusCode::OK);
    assert_eq!(
        health.into_body().collect().await.unwrap().to_bytes(),
        r#"{"status":"ok"}"#
    );

    let index = router(state)
        .oneshot(Request::get("/").body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(index.status(), StatusCode::OK);
    assert_eq!(
        index.into_body().collect().await.unwrap().to_bytes(),
        "pocket-agent-ui"
    );
}

#[tokio::test]
async fn websocket_requires_a_valid_token() {
    let servers = start_servers().await;
    let error = connect_async(format!("ws://{}/ws", servers.gateway_addr))
        .await
        .unwrap_err();
    match error {
        tokio_tungstenite::tungstenite::Error::Http(response) => {
            assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        }
        other => panic!("expected an HTTP authentication error, got {other}"),
    }
}

#[tokio::test]
async fn websocket_relays_text_and_binary_without_interpreting_them() {
    let servers = start_servers().await;
    let (mut websocket, _) = connect_async(format!(
        "ws://{}/ws?token=test-secret",
        servers.gateway_addr
    ))
    .await
    .unwrap();

    websocket
        .send(Message::Text(r#"{"jsonrpc":"2.0","id":1}"#.into()))
        .await
        .unwrap();
    assert_eq!(
        websocket.next().await.unwrap().unwrap(),
        Message::Text(r#"{"jsonrpc":"2.0","id":1}"#.into())
    );

    websocket
        .send(Message::Binary(vec![0, 1, 2, 255].into()))
        .await
        .unwrap();
    assert_eq!(
        websocket.next().await.unwrap().unwrap(),
        Message::Binary(vec![0, 1, 2, 255].into())
    );
}

#[tokio::test]
async fn shutdown_closes_active_websockets() {
    let servers = start_servers().await;
    let (mut websocket, _) = connect_async(format!(
        "ws://{}/ws?token=test-secret",
        servers.gateway_addr
    ))
    .await
    .unwrap();

    servers.state.begin_shutdown();
    let message = tokio::time::timeout(Duration::from_secs(1), websocket.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(message.is_close());
}
