use std::{
    net::SocketAddr,
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};

use thiserror::Error;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    process::Child,
};
use tracing::{info, warn};

use crate::AppState;

pub struct CodexProcess {
    child: Child,
}

impl CodexProcess {
    pub async fn stop(mut self) {
        match self.child.try_wait() {
            Ok(Some(status)) => {
                info!(%status, "managed Codex app-server already exited");
            }
            Ok(None) => {
                if let Err(error) = self.child.kill().await {
                    warn!(%error, "failed to stop managed Codex app-server");
                } else {
                    info!("managed Codex app-server stopped");
                }
            }
            Err(error) => warn!(%error, "failed to inspect managed Codex app-server"),
        }
    }
}

#[derive(Debug, Error)]
pub enum StartError {
    #[error("Codex app-server is unavailable and automatic startup is disabled")]
    AutoStartDisabled,
    #[error("failed to start Codex app-server: {0}")]
    Spawn(#[source] std::io::Error),
    #[error("Codex app-server exited before becoming ready: {0}")]
    Exited(std::process::ExitStatus),
    #[error("Codex app-server did not become ready within {0:?}")]
    TimedOut(Duration),
}

pub async fn ensure_codex_available(state: &AppState) -> Result<(), StartError> {
    if codex_is_ready(state.config.codex_socket_addr).await {
        info!(url = %state.config.codex_url, "using existing Codex app-server");
        return Ok(());
    }

    if !state.config.auto_start_codex {
        return Err(StartError::AutoStartDisabled);
    }

    let codex_bin = resolve_native_executable(&state.config.codex_bin);
    info!(
        command = %codex_bin.display(),
        url = %state.config.codex_url,
        "starting Codex app-server"
    );
    let child = tokio::process::Command::new(codex_bin)
        .arg("app-server")
        .arg("--listen")
        // `url::Url` serializes the root as a trailing slash, while Codex's
        // `--listen` parser deliberately requires the exact ws://IP:PORT form.
        .arg(format!("ws://{}", state.config.codex_socket_addr))
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .map_err(StartError::Spawn)?;

    let mut process = CodexProcess { child };
    let started = tokio::time::Instant::now();
    loop {
        if let Some(status) = process.child.try_wait().map_err(StartError::Spawn)? {
            return Err(StartError::Exited(status));
        }
        if codex_is_ready(state.config.codex_socket_addr).await {
            *state.codex_process.lock().await = Some(process);
            info!(url = %state.config.codex_url, "Codex app-server is ready");
            return Ok(());
        }
        if started.elapsed() >= state.config.codex_start_timeout {
            process.stop().await;
            return Err(StartError::TimedOut(state.config.codex_start_timeout));
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// Checks the HTTP readiness endpoint provided by a Codex WebSocket listener.
/// This avoids treating an unrelated process that merely occupies the port as ready.
pub async fn codex_is_ready(target: SocketAddr) -> bool {
    const TIMEOUT: Duration = Duration::from_millis(750);
    let Ok(Ok(mut stream)) = tokio::time::timeout(TIMEOUT, TcpStream::connect(target)).await else {
        return false;
    };

    let request = format!("GET /readyz HTTP/1.1\r\nHost: {target}\r\nConnection: close\r\n\r\n");
    if !matches!(
        tokio::time::timeout(TIMEOUT, stream.write_all(request.as_bytes())).await,
        Ok(Ok(()))
    ) {
        return false;
    }

    let mut response = [0_u8; 256];
    let status_line = async {
        let mut bytes_read = 0;
        loop {
            let read = stream.read(&mut response[bytes_read..]).await?;
            if read == 0 {
                return Ok::<usize, std::io::Error>(bytes_read);
            }
            bytes_read += read;
            if response[..bytes_read].contains(&b'\n') || bytes_read == response.len() {
                return Ok(bytes_read);
            }
        }
    };
    let Ok(Ok(bytes_read)) = tokio::time::timeout(TIMEOUT, status_line).await else {
        return false;
    };
    response[..bytes_read].starts_with(b"HTTP/1.1 200 ")
        || response[..bytes_read].starts_with(b"HTTP/1.0 200 ")
}

fn resolve_native_executable(configured: &Path) -> PathBuf {
    #[cfg(windows)]
    {
        // `Command` cannot directly execute npm's extensionless/`.cmd` shims.
        // Prefer a native executable anywhere on PATH so it remains a child we
        // can reliably terminate during graceful gateway shutdown.
        if configured.components().count() == 1 && configured.extension().is_none() {
            if let (Some(name), Some(search_path)) = (configured.to_str(), std::env::var_os("PATH"))
            {
                let directories: Vec<_> = std::env::split_paths(&search_path).collect();

                // Prefer ordinary native installations. Windows Store package
                // files can be visible but deny CreateProcess to desktop apps.
                for directory in &directories {
                    let candidate = directory.join(format!("{name}.exe"));
                    if candidate.is_file() && !is_windows_store_path(&candidate) {
                        return candidate;
                    }
                }

                // Global npm shims are scripts, but the package contains the
                // native binary. Resolve the two layouts used by npm releases.
                for directory in &directories {
                    for candidate in npm_codex_candidates(directory) {
                        if candidate.is_file() {
                            return candidate;
                        }
                    }
                }

                // Last resort for environments where Store ACLs do allow it.
                for directory in &directories {
                    let candidate = directory.join(format!("{name}.exe"));
                    if candidate.is_file() {
                        return candidate;
                    }
                }
            }
        }
    }

    configured.to_owned()
}

#[cfg(windows)]
fn is_windows_store_path(path: &Path) -> bool {
    path.to_string_lossy()
        .to_ascii_lowercase()
        .contains("\\windowsapps\\")
}

#[cfg(all(windows, target_arch = "x86_64"))]
const NPM_PLATFORM_PACKAGE: &str = "codex-win32-x64";
#[cfg(all(windows, target_arch = "aarch64"))]
const NPM_PLATFORM_PACKAGE: &str = "codex-win32-arm64";
#[cfg(all(windows, not(any(target_arch = "x86_64", target_arch = "aarch64"))))]
const NPM_PLATFORM_PACKAGE: &str = "unsupported";

#[cfg(all(windows, target_arch = "x86_64"))]
const NPM_TARGET: &str = "x86_64-pc-windows-msvc";
#[cfg(all(windows, target_arch = "aarch64"))]
const NPM_TARGET: &str = "aarch64-pc-windows-msvc";
#[cfg(all(windows, not(any(target_arch = "x86_64", target_arch = "aarch64"))))]
const NPM_TARGET: &str = "unsupported";

#[cfg(windows)]
fn npm_codex_candidates(prefix: &Path) -> [PathBuf; 2] {
    let package_relative = Path::new("@openai")
        .join(NPM_PLATFORM_PACKAGE)
        .join("vendor")
        .join(NPM_TARGET)
        .join("bin")
        .join("codex.exe");
    [
        prefix
            .join("node_modules")
            .join("@openai")
            .join("codex")
            .join("node_modules")
            .join(&package_relative),
        prefix.join("node_modules").join(package_relative),
    ]
}

pub async fn stop_managed_codex(state: &AppState) {
    if let Some(process) = state.codex_process.lock().await.take() {
        process.stop().await;
    }
}

#[cfg(test)]
mod tests {
    use tokio::net::TcpListener;

    use super::*;

    async fn readiness_response(status: &'static str) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = [0_u8; 512];
            let bytes_read = stream.read(&mut request).await.unwrap();
            assert!(request[..bytes_read].starts_with(b"GET /readyz HTTP/1.1\r\n"));
            stream
                .write_all(format!("HTTP/1.1 {status}\r\nContent-Length: 0\r\n\r\n").as_bytes())
                .await
                .unwrap();
        });
        address
    }

    #[tokio::test]
    async fn readiness_requires_an_http_200_from_codex_endpoint() {
        let ready = readiness_response("200 OK").await;
        assert!(codex_is_ready(ready).await);

        let unavailable = readiness_response("503 Service Unavailable").await;
        assert!(!codex_is_ready(unavailable).await);
    }
}
