use std::{
    ffi::OsString,
    net::{Ipv4Addr, SocketAddr},
    path::PathBuf,
    process::Stdio,
    sync::Arc,
    time::Duration,
};

use axum::{
    Json,
    extract::State,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};
use serde::{Deserialize, Serialize};
use tokio::{
    io::AsyncReadExt,
    net::TcpListener,
    process::{Child, Command},
    sync::Mutex,
    task::JoinHandle,
};
use tracing::{info, warn};
use url::Url;

use crate::{AppState, UpstreamTarget, app_server, auth};

const DEFAULT_REMOTE_CODEX_BIN: &str = "codex";
const MAX_CAPTURED_STDERR: usize = 8 * 1024;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshConnectRequest {
    pub target: String,
    pub port: Option<u16>,
    pub identity_file: Option<String>,
    pub remote_port: Option<u16>,
    pub remote_codex_bin: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SshStatus {
    pub mode: &'static str,
    pub connected: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub local_port: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote_port: Option<u16>,
}

pub struct SshSession {
    child: Child,
    stderr_task: JoinHandle<()>,
    connection: SshTerminalTarget,
    local_addr: SocketAddr,
    remote_port: u16,
}

#[derive(Debug, Clone)]
pub(crate) struct SshTerminalTarget {
    pub target: String,
    pub port: Option<u16>,
    pub identity_file: Option<String>,
}

impl SshSession {
    fn status(&self) -> SshStatus {
        SshStatus {
            mode: "ssh",
            connected: true,
            target: Some(self.connection.target.clone()),
            local_port: Some(self.local_addr.port()),
            remote_port: Some(self.remote_port),
        }
    }

    pub async fn stop(mut self) {
        match self.child.try_wait() {
            Ok(Some(status)) => info!(%status, "managed SSH session already exited"),
            Ok(None) => {
                if let Err(error) = self.child.kill().await {
                    warn!(%error, "failed to stop managed SSH session");
                } else {
                    info!(target = %self.connection.target, "managed SSH session stopped");
                }
            }
            Err(error) => warn!(%error, "failed to inspect managed SSH session"),
        }
        self.stderr_task.abort();
    }
}

#[derive(Debug, thiserror::Error)]
enum SshError {
    #[error("SSH target must be a host alias or user@host without whitespace or options")]
    InvalidTarget,
    #[error("remote Codex executable must not be empty")]
    InvalidCodexBin,
    #[error("{0} must be between 1 and 65535")]
    InvalidPort(&'static str),
    #[error("failed to reserve a local forwarding port: {0}")]
    ReservePort(#[source] std::io::Error),
    #[error("failed to start SSH: {0}")]
    Spawn(#[source] std::io::Error),
    #[error("SSH exited before remote Codex became ready: {0}{1}")]
    Exited(std::process::ExitStatus, CapturedError),
    #[error("remote Codex did not become ready through SSH within {0:?}{1}")]
    TimedOut(Duration, CapturedError),
}

#[derive(Debug)]
struct CapturedError(String);

impl std::fmt::Display for CapturedError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.0.is_empty() {
            Ok(())
        } else {
            write!(formatter, ": {}", self.0)
        }
    }
}

pub async fn connect_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<SshConnectRequest>,
) -> Response {
    if !auth::authorized(&headers, None, &state.config.token) {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }

    match start_session(&state, request).await {
        Ok(status) => (StatusCode::OK, Json(status)).into_response(),
        Err(error) => {
            warn!(%error, "failed to establish SSH session");
            (
                StatusCode::BAD_GATEWAY,
                Json(serde_json::json!({ "error": error.to_string() })),
            )
                .into_response()
        }
    }
}

pub async fn disconnect_handler(State(state): State<AppState>, headers: HeaderMap) -> Response {
    if !auth::authorized(&headers, None, &state.config.token) {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }

    stop_managed_ssh(&state).await;
    Json(local_status()).into_response()
}

pub async fn status_handler(State(state): State<AppState>, headers: HeaderMap) -> Response {
    if !auth::authorized(&headers, None, &state.config.token) {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }

    Json(current_status(&state).await).into_response()
}

async fn start_session(
    state: &AppState,
    request: SshConnectRequest,
) -> Result<SshStatus, SshError> {
    validate_target(&request.target)?;
    validate_request_ports(&request)?;
    let remote_codex_bin = request
        .remote_codex_bin
        .as_deref()
        .unwrap_or(DEFAULT_REMOTE_CODEX_BIN)
        .trim();
    if remote_codex_bin.is_empty() {
        return Err(SshError::InvalidCodexBin);
    }
    let remote_port = request.remote_port.unwrap_or(state.config.ssh_remote_port);

    let reservation = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
        .await
        .map_err(SshError::ReservePort)?;
    let local_addr = reservation.local_addr().map_err(SshError::ReservePort)?;
    drop(reservation);

    let args = build_ssh_args(&request, local_addr.port(), remote_port, remote_codex_bin);
    info!(target = %request.target, local_port = local_addr.port(), remote_port, "starting managed SSH session");
    let mut child = Command::new(&state.config.ssh_bin)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(SshError::Spawn)?;

    let captured_stderr = Arc::new(Mutex::new(Vec::new()));
    let stderr = child.stderr.take();
    let stderr_task = capture_stderr(stderr, Arc::clone(&captured_stderr));
    let started = tokio::time::Instant::now();

    loop {
        if let Some(status) = child.try_wait().map_err(SshError::Spawn)? {
            tokio::time::sleep(Duration::from_millis(20)).await;
            stderr_task.abort();
            return Err(SshError::Exited(
                status,
                captured_error(&captured_stderr).await,
            ));
        }
        if app_server::codex_is_ready(local_addr).await {
            let session = SshSession {
                child,
                stderr_task,
                connection: SshTerminalTarget {
                    target: request.target,
                    port: request.port,
                    identity_file: request.identity_file,
                },
                local_addr,
                remote_port,
            };
            let status = session.status();
            let upstream = UpstreamTarget {
                url: Url::parse(&format!("ws://{local_addr}")).expect("local WebSocket URL"),
                socket_addr: local_addr,
                mode: "ssh",
            };
            state.reset_ssh_terminals();
            let previous = state.ssh_session.lock().await.replace(session);
            *state.upstream.write().await = upstream;
            if let Some(previous) = previous {
                previous.stop().await;
            }
            info!(target = ?status.target, "remote Codex is ready through SSH");
            return Ok(status);
        }
        if started.elapsed() >= state.config.ssh_start_timeout {
            let _ = child.kill().await;
            stderr_task.abort();
            return Err(SshError::TimedOut(
                state.config.ssh_start_timeout,
                captured_error(&captured_stderr).await,
            ));
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

fn capture_stderr(
    stderr: Option<tokio::process::ChildStderr>,
    captured: Arc<Mutex<Vec<u8>>>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let Some(mut stderr) = stderr else {
            return;
        };
        let mut buffer = [0_u8; 1024];
        loop {
            let Ok(bytes_read) = stderr.read(&mut buffer).await else {
                break;
            };
            if bytes_read == 0 {
                break;
            }
            let mut captured = captured.lock().await;
            captured.extend_from_slice(&buffer[..bytes_read]);
            if captured.len() > MAX_CAPTURED_STDERR {
                let excess = captured.len() - MAX_CAPTURED_STDERR;
                captured.drain(..excess);
            }
        }
    })
}

async fn captured_error(captured: &Mutex<Vec<u8>>) -> CapturedError {
    let bytes = captured.lock().await;
    let text = String::from_utf8_lossy(&bytes).trim().to_owned();
    CapturedError(text)
}

fn build_ssh_args(
    request: &SshConnectRequest,
    local_port: u16,
    remote_port: u16,
    remote_codex_bin: &str,
) -> Vec<OsString> {
    let mut args = vec![
        OsString::from("-T"),
        OsString::from("-o"),
        OsString::from("BatchMode=yes"),
        OsString::from("-o"),
        OsString::from("ExitOnForwardFailure=yes"),
        OsString::from("-o"),
        OsString::from("ServerAliveInterval=15"),
        OsString::from("-o"),
        OsString::from("ServerAliveCountMax=3"),
        OsString::from("-o"),
        OsString::from("ConnectTimeout=10"),
    ];
    if let Some(port) = request.port {
        args.push(OsString::from("-p"));
        args.push(OsString::from(port.to_string()));
    }
    if let Some(identity_file) = request
        .identity_file
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        args.push(OsString::from("-i"));
        args.push(PathBuf::from(identity_file).into_os_string());
    }
    args.push(OsString::from("-L"));
    args.push(OsString::from(format!(
        "127.0.0.1:{local_port}:127.0.0.1:{remote_port}"
    )));
    args.push(OsString::from("--"));
    args.push(OsString::from(&request.target));
    args.push(OsString::from(format!(
        "exec {} app-server --listen {}",
        shell_quote(remote_codex_bin),
        shell_quote(&format!("ws://127.0.0.1:{remote_port}"))
    )));
    args
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn validate_target(target: &str) -> Result<(), SshError> {
    if target.is_empty()
        || target.len() > 255
        || target.starts_with('-')
        || !target.bytes().all(|byte| {
            byte.is_ascii_alphanumeric()
                || matches!(byte, b'-' | b'_' | b'.' | b'@' | b':' | b'[' | b']')
        })
    {
        return Err(SshError::InvalidTarget);
    }
    Ok(())
}

fn validate_request_ports(request: &SshConnectRequest) -> Result<(), SshError> {
    if request.port == Some(0) {
        return Err(SshError::InvalidPort("SSH port"));
    }
    if request.remote_port == Some(0) {
        return Err(SshError::InvalidPort("remote app-server port"));
    }
    Ok(())
}

async fn current_status(state: &AppState) -> SshStatus {
    let mut session = state.ssh_session.lock().await;
    let exited = match session.as_mut() {
        Some(session) => matches!(session.child.try_wait(), Ok(Some(_)) | Err(_)),
        None => false,
    };
    if exited {
        let stale = session.take();
        drop(session);
        if let Some(stale) = stale {
            stale.stop().await;
        }
        *state.upstream.write().await = state.local_upstream();
        local_status()
    } else {
        session
            .as_ref()
            .map(SshSession::status)
            .unwrap_or_else(local_status)
    }
}

fn local_status() -> SshStatus {
    SshStatus {
        mode: "local",
        connected: false,
        target: None,
        local_port: None,
        remote_port: None,
    }
}

pub async fn stop_managed_ssh(state: &AppState) {
    state.reset_ssh_terminals();
    if let Some(session) = state.ssh_session.lock().await.take() {
        *state.upstream.write().await = state.local_upstream();
        session.stop().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(target: &str) -> SshConnectRequest {
        SshConnectRequest {
            target: target.to_owned(),
            port: Some(2222),
            identity_file: Some("/keys/id ed25519".to_owned()),
            remote_port: Some(4600),
            remote_codex_bin: Some("/opt/Codex Agent/bin/codex".to_owned()),
        }
    }

    #[test]
    fn rejects_option_or_shell_shaped_targets() {
        for target in ["", "-oProxyCommand=bad", "host name", "host;touch"] {
            assert!(validate_target(target).is_err(), "accepted {target:?}");
        }
        for target in ["prod", "deploy@prod-1", "user@[::1]"] {
            assert!(validate_target(target).is_ok(), "rejected {target:?}");
        }
    }

    #[test]
    fn builds_argument_safe_ssh_command() {
        let args = build_ssh_args(
            &request("deploy@prod"),
            12345,
            4600,
            "/opt/Codex Agent/bin/codex",
        );
        let args: Vec<_> = args
            .iter()
            .map(|value| value.to_string_lossy().into_owned())
            .collect();
        assert!(args.windows(2).any(|pair| pair == ["-p", "2222"]));
        assert!(
            args.windows(2)
                .any(|pair| pair == ["-i", "/keys/id ed25519"])
        );
        assert!(args.contains(&"127.0.0.1:12345:127.0.0.1:4600".to_owned()));
        assert_eq!(args[args.len() - 2], "deploy@prod");
        assert_eq!(
            args.last().unwrap(),
            "exec '/opt/Codex Agent/bin/codex' app-server --listen 'ws://127.0.0.1:4600'"
        );
    }

    #[test]
    fn quotes_remote_shell_values() {
        assert_eq!(shell_quote("a'b"), "'a'\"'\"'b'");
    }

    #[test]
    fn rejects_zero_ports_before_spawning_ssh() {
        let mut ssh_port = request("prod");
        ssh_port.port = Some(0);
        assert!(matches!(
            validate_request_ports(&ssh_port),
            Err(SshError::InvalidPort("SSH port"))
        ));

        let mut remote_port = request("prod");
        remote_port.remote_port = Some(0);
        assert!(matches!(
            validate_request_ports(&remote_port),
            Err(SshError::InvalidPort("remote app-server port"))
        ));
    }
}
