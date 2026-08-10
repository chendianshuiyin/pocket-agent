use std::{net::SocketAddr, path::PathBuf, time::Duration};

use axum::{
    body::Body,
    http::{Request, StatusCode, header::SEC_WEBSOCKET_PROTOCOL},
};
use futures_util::{SinkExt, StreamExt};
use http_body_util::BodyExt;
use pocket_agent_gateway::{AppState, Config, router};
use tempfile::TempDir;
use tokio::{net::TcpListener, task::JoinHandle};
use tokio_tungstenite::{
    accept_async, connect_async,
    tungstenite::{Message, client::IntoClientRequest},
};
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
        ssh_bin: PathBuf::from("ssh"),
        ssh_start_timeout: Duration::from_secs(1),
        ssh_remote_port: 4500,
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
        ssh_bin: PathBuf::from("ssh"),
        ssh_start_timeout: Duration::from_secs(1),
        ssh_remote_port: 4500,
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
async fn ssh_control_api_requires_authentication_and_validates_targets() {
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
        ssh_bin: PathBuf::from("ssh"),
        ssh_start_timeout: Duration::from_secs(1),
        ssh_remote_port: 4500,
        frontend_dir: frontend.path().to_owned(),
    });

    let unauthorized = router(state.clone())
        .oneshot(Request::get("/api/ssh/status").body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(unauthorized.status(), StatusCode::UNAUTHORIZED);

    let status = router(state.clone())
        .oneshot(
            Request::get("/api/ssh/status")
                .header("x-pocket-agent-token", "test-secret")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(status.status(), StatusCode::OK);
    assert_eq!(
        status.into_body().collect().await.unwrap().to_bytes(),
        r#"{"mode":"local","connected":false}"#
    );

    let invalid_target = router(state)
        .oneshot(
            Request::post("/api/ssh/connect")
                .header("content-type", "application/json")
                .header("x-pocket-agent-token", "test-secret")
                .body(Body::from(r#"{"target":"-oProxyCommand=bad"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(invalid_target.status(), StatusCode::BAD_GATEWAY);
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
async fn ssh_terminal_websocket_requires_auth_and_validates_the_start_message() {
    let servers = start_servers().await;
    let unauthorized = connect_async(format!("ws://{}/terminal/ws", servers.gateway_addr))
        .await
        .unwrap_err();
    match unauthorized {
        tokio_tungstenite::tungstenite::Error::Http(response) => {
            assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        }
        other => panic!("expected an HTTP authentication error, got {other}"),
    }

    let (mut terminal, _) = connect_async(format!(
        "ws://{}/terminal/ws?token=test-secret",
        servers.gateway_addr
    ))
    .await
    .unwrap();
    terminal
        .send(Message::Text(
            r#"{"type":"start","sessionId":"term-1","target":"-oBad","rows":24,"cols":80}"#.into(),
        ))
        .await
        .unwrap();
    let message = terminal.next().await.unwrap().unwrap().into_text().unwrap();
    assert!(message.contains("invalid terminal start message"));
}

#[tokio::test]
async fn websocket_relays_text_and_binary_without_interpreting_them() {
    let servers = start_servers().await;
    let mut request = format!("ws://{}/ws", servers.gateway_addr)
        .into_client_request()
        .unwrap();
    request.headers_mut().insert(
        SEC_WEBSOCKET_PROTOCOL,
        "pocket-agent-token.746573742d736563726574".parse().unwrap(),
    );
    let (mut websocket, response) = connect_async(request).await.unwrap();
    assert_eq!(
        response.headers().get(SEC_WEBSOCKET_PROTOCOL).unwrap(),
        "pocket-agent-token.746573742d736563726574"
    );

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
