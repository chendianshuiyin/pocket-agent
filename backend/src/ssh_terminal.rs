use std::{
    ffi::OsString,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{Arc, Mutex as StdMutex},
};

use axum::{
    extract::{
        Query, State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use futures_util::{SinkExt, StreamExt};
use portable_pty::{ChildKiller, CommandBuilder, MasterPty, PtySize, native_pty_system};
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, oneshot, watch};
use tracing::{info, warn};

use crate::{AppState, auth, ssh::SshTerminalTarget};

const START_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
const MAX_INPUT_BYTES: usize = 64 * 1024;

#[derive(Deserialize)]
pub struct AuthQuery {
    token: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum ClientMessage {
    Start {
        session_id: String,
        target: String,
        port: Option<u16>,
        identity_file: Option<String>,
        cwd: Option<String>,
        rows: u16,
        cols: u16,
    },
    Input {
        data_base64: String,
    },
    Resize {
        rows: u16,
        cols: u16,
    },
    Close,
}

#[derive(Debug, Serialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum ServerMessage<'a> {
    Ready { session_id: &'a str },
    Output { data_base64: String },
    Exit { exit_code: u32 },
    Error { message: &'a str },
}

struct RunningPty {
    master: Arc<StdMutex<Box<dyn MasterPty + Send>>>,
    writer: Arc<StdMutex<Box<dyn Write + Send>>>,
    killer: Arc<StdMutex<Box<dyn ChildKiller + Send + Sync>>>,
    output: mpsc::Receiver<Vec<u8>>,
    exit: oneshot::Receiver<Result<u32, String>>,
}

pub async fn websocket_handler(
    State(state): State<AppState>,
    Query(query): Query<AuthQuery>,
    headers: HeaderMap,
    upgrade: WebSocketUpgrade,
) -> Response {
    let selected_protocol = auth::websocket_protocol(&headers, &state.config.token);
    if !auth::authorized(&headers, query.token.as_deref(), &state.config.token) {
        return (StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    let ssh_bin = state.config.ssh_bin.clone();
    let shutdown = state.subscribe_shutdown();
    let terminal_generation = state.subscribe_ssh_terminal_generation();
    match selected_protocol {
        Some(protocol) => upgrade
            .protocols([protocol])
            .on_upgrade(move |socket| relay(socket, ssh_bin, shutdown, terminal_generation)),
        None => {
            upgrade.on_upgrade(move |socket| relay(socket, ssh_bin, shutdown, terminal_generation))
        }
    }
}

async fn relay(
    mut socket: WebSocket,
    ssh_bin: PathBuf,
    mut shutdown: watch::Receiver<bool>,
    mut terminal_generation: watch::Receiver<u64>,
) {
    let start = match tokio::time::timeout(START_TIMEOUT, socket.recv()).await {
        Ok(Some(Ok(Message::Text(text)))) => serde_json::from_str::<ClientMessage>(&text),
        _ => {
            send_server_message(
                &mut socket,
                &ServerMessage::Error {
                    message: "terminal start message timed out",
                },
            )
            .await;
            return;
        }
    };
    let (session_id, target, cwd, rows, cols) = match start {
        Ok(ClientMessage::Start {
            session_id,
            target,
            port,
            identity_file,
            cwd,
            rows,
            cols,
        }) if valid_session_id(&session_id)
            && valid_target(&target)
            && port != Some(0)
            && valid_identity_file(identity_file.as_deref())
            && valid_size(rows, cols)
            && valid_cwd(cwd.as_deref()) =>
        {
            (
                session_id,
                SshTerminalTarget {
                    target,
                    port,
                    identity_file,
                },
                cwd,
                rows,
                cols,
            )
        }
        _ => {
            send_server_message(
                &mut socket,
                &ServerMessage::Error {
                    message: "invalid terminal start message",
                },
            )
            .await;
            return;
        }
    };

    let target_label = target.target.clone();
    let pty = match tokio::task::spawn_blocking(move || {
        spawn_ssh_pty(&ssh_bin, &target, cwd.as_deref(), rows, cols)
    })
    .await
    {
        Ok(Ok(pty)) => pty,
        Ok(Err(error)) => {
            send_server_message(&mut socket, &ServerMessage::Error { message: &error }).await;
            return;
        }
        Err(error) => {
            let message = format!("failed to start SSH PTY task: {error}");
            send_server_message(&mut socket, &ServerMessage::Error { message: &message }).await;
            return;
        }
    };

    info!(session_id = %session_id, target = %target_label, "SSH terminal opened");
    let (mut client_tx, mut client_rx) = socket.split();
    if send_split_message(
        &mut client_tx,
        &ServerMessage::Ready {
            session_id: &session_id,
        },
    )
    .await
    .is_err()
    {
        kill_pty(&pty.killer).await;
        return;
    }

    let RunningPty {
        master,
        writer,
        killer,
        mut output,
        mut exit,
    } = pty;
    loop {
        tokio::select! {
            client_message = client_rx.next() => {
                match client_message {
                    Some(Ok(Message::Text(text))) => match serde_json::from_str::<ClientMessage>(&text) {
                        Ok(ClientMessage::Input { data_base64 }) => {
                            let Ok(data) = BASE64.decode(data_base64) else {
                                let _ = send_split_message(&mut client_tx, &ServerMessage::Error { message: "invalid base64 terminal input" }).await;
                                continue;
                            };
                            if data.len() > MAX_INPUT_BYTES {
                                let _ = send_split_message(&mut client_tx, &ServerMessage::Error { message: "terminal input exceeds 64 KiB" }).await;
                                continue;
                            }
                            if let Err(error) = write_pty(Arc::clone(&writer), data).await {
                                let _ = send_split_message(&mut client_tx, &ServerMessage::Error { message: &error }).await;
                            }
                        }
                        Ok(ClientMessage::Resize { rows, cols }) if valid_size(rows, cols) => {
                            if let Err(error) = resize_pty(Arc::clone(&master), rows, cols).await {
                                let _ = send_split_message(&mut client_tx, &ServerMessage::Error { message: &error }).await;
                            }
                        }
                        Ok(ClientMessage::Close) => break,
                        _ => {
                            let _ = send_split_message(&mut client_tx, &ServerMessage::Error { message: "invalid terminal message" }).await;
                        }
                    },
                    Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                    _ => {}
                }
            }
            chunk = output.recv() => {
                let Some(chunk) = chunk else { continue };
                if send_split_message(&mut client_tx, &ServerMessage::Output { data_base64: BASE64.encode(chunk) }).await.is_err() {
                    break;
                }
            }
            status = &mut exit => {
                match status {
                    Ok(Ok(exit_code)) => { let _ = send_split_message(&mut client_tx, &ServerMessage::Exit { exit_code }).await; }
                    Ok(Err(error)) => { let _ = send_split_message(&mut client_tx, &ServerMessage::Error { message: &error }).await; }
                    Err(_) => { let _ = send_split_message(&mut client_tx, &ServerMessage::Error { message: "SSH PTY wait task stopped" }).await; }
                }
                break;
            }
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() { break; }
            }
            _ = terminal_generation.changed() => break,
        }
    }
    kill_pty(&killer).await;
    info!(session_id = %session_id, "SSH terminal closed");
}

fn spawn_ssh_pty(
    ssh_bin: &Path,
    target: &SshTerminalTarget,
    cwd: Option<&str>,
    rows: u16,
    cols: u16,
) -> Result<RunningPty, String> {
    let pair = native_pty_system()
        .openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|error| format!("failed to allocate PTY: {error}"))?;
    let mut command = CommandBuilder::new(ssh_bin);
    for argument in build_terminal_ssh_args(target, cwd) {
        command.arg(argument);
    }
    let mut child = pair
        .slave
        .spawn_command(command)
        .map_err(|error| format!("failed to start SSH terminal: {error}"))?;
    drop(pair.slave);
    let mut reader = pair
        .master
        .try_clone_reader()
        .map_err(|error| format!("failed to open PTY output: {error}"))?;
    let writer = pair
        .master
        .take_writer()
        .map_err(|error| format!("failed to open PTY input: {error}"))?;
    let killer = child.clone_killer();
    let master = Arc::new(StdMutex::new(pair.master));
    let writer = Arc::new(StdMutex::new(writer));
    let killer = Arc::new(StdMutex::new(killer));
    let (output_tx, output) = mpsc::channel(64);
    tokio::task::spawn_blocking(move || {
        let mut buffer = [0_u8; 8192];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(read) if output_tx.blocking_send(buffer[..read].to_vec()).is_err() => break,
                Ok(_) => {}
            }
        }
    });
    let (exit_tx, exit) = oneshot::channel();
    tokio::task::spawn_blocking(move || {
        let status = child
            .wait()
            .map(|status| status.exit_code())
            .map_err(|error| format!("failed waiting for SSH terminal: {error}"));
        let _ = exit_tx.send(status);
    });
    Ok(RunningPty {
        master,
        writer,
        killer,
        output,
        exit,
    })
}

fn build_terminal_ssh_args(target: &SshTerminalTarget, cwd: Option<&str>) -> Vec<OsString> {
    let mut args = vec![
        OsString::from("-tt"),
        OsString::from("-o"),
        OsString::from("BatchMode=yes"),
        OsString::from("-o"),
        OsString::from("ServerAliveInterval=15"),
        OsString::from("-o"),
        OsString::from("ServerAliveCountMax=3"),
        OsString::from("-o"),
        OsString::from("ConnectTimeout=10"),
    ];
    if let Some(port) = target.port {
        args.extend([OsString::from("-p"), OsString::from(port.to_string())]);
    }
    if let Some(identity_file) = target
        .identity_file
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        args.extend([
            OsString::from("-i"),
            PathBuf::from(identity_file).into_os_string(),
        ]);
    }
    args.extend([OsString::from("--"), OsString::from(&target.target)]);
    if let Some(cwd) = cwd.map(str::trim).filter(|value| !value.is_empty()) {
        args.push(OsString::from(format!(
            "cd -- {} && exec \"${{SHELL:-/bin/sh}}\" -l",
            shell_quote(cwd)
        )));
    }
    args
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn valid_session_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn valid_target(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 255
        && !value.starts_with('-')
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric()
                || matches!(byte, b'-' | b'_' | b'.' | b'@' | b':' | b'[' | b']')
        })
}

fn valid_identity_file(value: Option<&str>) -> bool {
    value.is_none_or(|path| path.len() <= 4096 && !path.contains('\0'))
}

fn valid_size(rows: u16, cols: u16) -> bool {
    (4..=200).contains(&rows) && (20..=400).contains(&cols)
}

fn valid_cwd(cwd: Option<&str>) -> bool {
    cwd.is_none_or(|value| value.len() <= 4096 && !value.contains('\0'))
}

async fn write_pty(
    writer: Arc<StdMutex<Box<dyn Write + Send>>>,
    data: Vec<u8>,
) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        let mut writer = writer
            .lock()
            .map_err(|_| "SSH PTY writer lock failed".to_owned())?;
        writer
            .write_all(&data)
            .and_then(|_| writer.flush())
            .map_err(|error| format!("failed writing SSH PTY: {error}"))
    })
    .await
    .map_err(|error| format!("SSH PTY write task failed: {error}"))?
}

async fn resize_pty(
    master: Arc<StdMutex<Box<dyn MasterPty + Send>>>,
    rows: u16,
    cols: u16,
) -> Result<(), String> {
    tokio::task::spawn_blocking(move || {
        let master = master
            .lock()
            .map_err(|_| "SSH PTY resize lock failed".to_owned())?;
        master
            .resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|error| format!("failed resizing SSH PTY: {error}"))
    })
    .await
    .map_err(|error| format!("SSH PTY resize task failed: {error}"))?
}

async fn kill_pty(killer: &Arc<StdMutex<Box<dyn ChildKiller + Send + Sync>>>) {
    let killer = Arc::clone(killer);
    let result = tokio::task::spawn_blocking(move || {
        killer
            .lock()
            .map_err(|_| "SSH PTY killer lock failed".to_owned())?
            .kill()
            .map_err(|error| error.to_string())
    })
    .await;
    match result {
        Ok(Ok(())) => {}
        Ok(Err(error)) => warn!(%error, "failed to kill SSH PTY"),
        Err(error) => warn!(%error, "SSH PTY kill task failed"),
    }
}

async fn send_server_message(socket: &mut WebSocket, message: &ServerMessage<'_>) {
    if let Ok(text) = serde_json::to_string(message) {
        let _ = socket.send(Message::Text(text.into())).await;
    }
}

async fn send_split_message(
    sender: &mut futures_util::stream::SplitSink<WebSocket, Message>,
    message: &ServerMessage<'_>,
) -> Result<(), axum::Error> {
    let text = serde_json::to_string(message)
        .unwrap_or_else(|_| "{\"type\":\"error\",\"message\":\"serialization failed\"}".to_owned());
    sender.send(Message::Text(text.into())).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target() -> SshTerminalTarget {
        SshTerminalTarget {
            target: "deploy@prod".to_owned(),
            port: Some(2222),
            identity_file: Some("/keys/id ed25519".to_owned()),
        }
    }

    #[test]
    fn builds_argument_safe_interactive_ssh_command() {
        let args: Vec<_> = build_terminal_ssh_args(&target(), Some("/srv/app's repo"))
            .into_iter()
            .map(|value| value.to_string_lossy().into_owned())
            .collect();
        assert_eq!(args[0], "-tt");
        assert!(args.windows(2).any(|pair| pair == ["-p", "2222"]));
        assert!(
            args.windows(2)
                .any(|pair| pair == ["-i", "/keys/id ed25519"])
        );
        assert_eq!(args[args.len() - 2], "deploy@prod");
        assert_eq!(
            args.last().unwrap(),
            "cd -- '/srv/app'\"'\"'s repo' && exec \"${SHELL:-/bin/sh}\" -l"
        );
    }

    #[test]
    fn validates_terminal_start_boundaries() {
        assert!(valid_session_id("term-a_1"));
        assert!(!valid_session_id("term/a"));
        assert!(valid_target("deploy@prod-1"));
        assert!(!valid_target("-oProxyCommand=bad"));
        assert!(valid_identity_file(Some("/keys/id_ed25519")));
        assert!(!valid_identity_file(Some("bad\0path")));
        assert!(valid_size(24, 80));
        assert!(!valid_size(1, 80));
        assert!(valid_cwd(Some("/srv/app")));
        assert!(!valid_cwd(Some("bad\0path")));
    }

    #[test]
    fn server_messages_use_camel_case_wire_format() {
        let message = serde_json::to_string(&ServerMessage::Output {
            data_base64: "eA==".to_owned(),
        })
        .unwrap();
        assert_eq!(message, r#"{"type":"output","dataBase64":"eA=="}"#);
    }
}
