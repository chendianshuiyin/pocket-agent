use std::{path::PathBuf, time::Duration};

use futures_util::SinkExt;
use pocket_agent_gateway::{AppState, Config, app_server::codex_is_ready, ensure_codex_available};
use tokio::net::TcpListener;
use tokio_tungstenite::{connect_async, tungstenite::Message};
use url::Url;

/// Run explicitly with `cargo test --test managed_codex -- --ignored` on a
/// machine that has an authenticated Codex CLI installation.
#[tokio::test]
#[ignore = "requires the Codex CLI executable"]
async fn starts_probes_and_stops_a_real_codex_app_server() {
    let reservation = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let codex_addr = reservation.local_addr().unwrap();
    drop(reservation);

    let frontend = tempfile::tempdir().unwrap();
    let state = AppState::new(Config {
        bind_addr: "127.0.0.1:0".parse().unwrap(),
        token: "test-secret".to_owned(),
        codex_url: Url::parse(&format!("ws://{codex_addr}")).unwrap(),
        codex_socket_addr: codex_addr,
        auto_start_codex: true,
        codex_bin: PathBuf::from("codex"),
        codex_start_timeout: Duration::from_secs(10),
        ssh_bin: PathBuf::from("ssh"),
        ssh_start_timeout: Duration::from_secs(1),
        ssh_remote_port: 4500,
        frontend_dir: frontend.path().to_owned(),
    });

    ensure_codex_available(&state).await.unwrap();
    assert!(codex_is_ready(codex_addr).await);

    let (mut websocket, _) = connect_async(state.config.codex_url.as_str())
        .await
        .unwrap();
    websocket.send(Message::Close(None)).await.unwrap();

    pocket_agent_gateway::app_server::stop_managed_codex(&state).await;
    assert!(!codex_is_ready(codex_addr).await);
}
