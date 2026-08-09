use std::{
    env,
    net::{IpAddr, SocketAddr},
    path::PathBuf,
    str::FromStr,
    time::Duration,
};

use thiserror::Error;
use url::Url;

const DEFAULT_BIND: &str = "127.0.0.1:8787";
const DEFAULT_CODEX_URL: &str = "ws://127.0.0.1:8765";
const DEFAULT_FRONTEND_DIR: &str = "frontend/dist";
const DEFAULT_SSH_REMOTE_PORT: u16 = 4500;

#[derive(Debug, Clone)]
pub struct Config {
    pub bind_addr: SocketAddr,
    pub token: String,
    pub codex_url: Url,
    pub codex_socket_addr: SocketAddr,
    pub auto_start_codex: bool,
    pub codex_bin: PathBuf,
    pub codex_start_timeout: Duration,
    pub ssh_bin: PathBuf,
    pub ssh_start_timeout: Duration,
    pub ssh_remote_port: u16,
    pub frontend_dir: PathBuf,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ConfigError {
    #[error("POCKET_AGENT_TOKEN must be set and must not be empty")]
    MissingToken,
    #[error("invalid POCKET_AGENT_BIND_ADDR: {0}")]
    InvalidBindAddress(String),
    #[error(
        "refusing non-loopback bind address {0}; set POCKET_AGENT_ALLOW_REMOTE=true to allow it"
    )]
    RemoteBindForbidden(SocketAddr),
    #[error("invalid POCKET_AGENT_CODEX_URL: {0}")]
    InvalidCodexUrl(String),
    #[error("POCKET_AGENT_CODEX_URL must use ws:// and point to a loopback IP address")]
    UnsafeCodexUrl,
    #[error("invalid boolean in {0}: expected true or false")]
    InvalidBoolean(&'static str),
    #[error("invalid POCKET_AGENT_CODEX_START_TIMEOUT_MS: {0}")]
    InvalidStartTimeout(String),
    #[error("invalid POCKET_AGENT_SSH_START_TIMEOUT_MS: {0}")]
    InvalidSshStartTimeout(String),
    #[error("invalid POCKET_AGENT_SSH_REMOTE_PORT: {0}")]
    InvalidSshRemotePort(String),
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        Self::from_getter(|name| env::var(name).ok())
    }

    fn from_getter(mut get: impl FnMut(&str) -> Option<String>) -> Result<Self, ConfigError> {
        let token = get("POCKET_AGENT_TOKEN")
            .filter(|value| !value.is_empty())
            .ok_or(ConfigError::MissingToken)?;

        let bind_raw = get("POCKET_AGENT_BIND_ADDR").unwrap_or_else(|| DEFAULT_BIND.to_owned());
        let bind_addr = SocketAddr::from_str(&bind_raw)
            .map_err(|_| ConfigError::InvalidBindAddress(bind_raw.clone()))?;
        let allow_remote = parse_bool(
            "POCKET_AGENT_ALLOW_REMOTE",
            get("POCKET_AGENT_ALLOW_REMOTE").as_deref(),
            false,
        )?;
        if !bind_addr.ip().is_loopback() && !allow_remote {
            return Err(ConfigError::RemoteBindForbidden(bind_addr));
        }

        let codex_raw =
            get("POCKET_AGENT_CODEX_URL").unwrap_or_else(|| DEFAULT_CODEX_URL.to_owned());
        let codex_url =
            Url::parse(&codex_raw).map_err(|_| ConfigError::InvalidCodexUrl(codex_raw.clone()))?;
        let codex_socket_addr = loopback_ws_socket_addr(&codex_url)?;

        let auto_start_codex = parse_bool(
            "POCKET_AGENT_AUTO_START_CODEX",
            get("POCKET_AGENT_AUTO_START_CODEX").as_deref(),
            true,
        )?;
        let codex_bin = get("POCKET_AGENT_CODEX_BIN")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("codex"));
        let timeout_raw =
            get("POCKET_AGENT_CODEX_START_TIMEOUT_MS").unwrap_or_else(|| "10000".to_owned());
        let timeout_ms = timeout_raw
            .parse::<u64>()
            .ok()
            .filter(|value| *value > 0)
            .ok_or_else(|| ConfigError::InvalidStartTimeout(timeout_raw.clone()))?;
        let ssh_bin = get("POCKET_AGENT_SSH_BIN")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("ssh"));
        let ssh_timeout_raw =
            get("POCKET_AGENT_SSH_START_TIMEOUT_MS").unwrap_or_else(|| "20000".to_owned());
        let ssh_timeout_ms = ssh_timeout_raw
            .parse::<u64>()
            .ok()
            .filter(|value| *value > 0)
            .ok_or_else(|| ConfigError::InvalidSshStartTimeout(ssh_timeout_raw.clone()))?;
        let ssh_remote_port_raw = get("POCKET_AGENT_SSH_REMOTE_PORT")
            .unwrap_or_else(|| DEFAULT_SSH_REMOTE_PORT.to_string());
        let ssh_remote_port = ssh_remote_port_raw
            .parse::<u16>()
            .ok()
            .filter(|value| *value > 0)
            .ok_or_else(|| ConfigError::InvalidSshRemotePort(ssh_remote_port_raw.clone()))?;
        let frontend_dir = get("POCKET_AGENT_FRONTEND_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(DEFAULT_FRONTEND_DIR));

        Ok(Self {
            bind_addr,
            token,
            codex_url,
            codex_socket_addr,
            auto_start_codex,
            codex_bin,
            codex_start_timeout: Duration::from_millis(timeout_ms),
            ssh_bin,
            ssh_start_timeout: Duration::from_millis(ssh_timeout_ms),
            ssh_remote_port,
            frontend_dir,
        })
    }
}

fn parse_bool(name: &'static str, raw: Option<&str>, default: bool) -> Result<bool, ConfigError> {
    match raw {
        None => Ok(default),
        Some(value) if value.eq_ignore_ascii_case("true") => Ok(true),
        Some(value) if value.eq_ignore_ascii_case("false") => Ok(false),
        Some(_) => Err(ConfigError::InvalidBoolean(name)),
    }
}

fn loopback_ws_socket_addr(url: &Url) -> Result<SocketAddr, ConfigError> {
    if url.scheme() != "ws"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(ConfigError::UnsafeCodexUrl);
    }

    let host = url.host_str().ok_or(ConfigError::UnsafeCodexUrl)?;
    let ip: IpAddr = host.parse().map_err(|_| ConfigError::UnsafeCodexUrl)?;
    if !ip.is_loopback() {
        return Err(ConfigError::UnsafeCodexUrl);
    }
    let port = url.port().ok_or(ConfigError::UnsafeCodexUrl)?;
    Ok(SocketAddr::new(ip, port))
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;

    fn config(values: &[(&str, &str)]) -> Result<Config, ConfigError> {
        let values: HashMap<String, String> = values
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect();
        Config::from_getter(|name| values.get(name).cloned())
    }

    #[test]
    fn secure_defaults_are_loopback_and_auto_start() {
        let config = config(&[("POCKET_AGENT_TOKEN", "secret")]).unwrap();
        assert_eq!(config.bind_addr, "127.0.0.1:8787".parse().unwrap());
        assert_eq!(config.codex_socket_addr, "127.0.0.1:8765".parse().unwrap());
        assert!(config.auto_start_codex);
        assert_eq!(config.ssh_remote_port, 4500);
        assert_eq!(config.ssh_start_timeout, Duration::from_secs(20));
    }

    #[test]
    fn token_is_required() {
        assert_eq!(config(&[]).unwrap_err(), ConfigError::MissingToken);
    }

    #[test]
    fn remote_bind_requires_explicit_opt_in() {
        let error = config(&[
            ("POCKET_AGENT_TOKEN", "secret"),
            ("POCKET_AGENT_BIND_ADDR", "0.0.0.0:8787"),
        ])
        .unwrap_err();
        assert!(matches!(error, ConfigError::RemoteBindForbidden(_)));

        let allowed = config(&[
            ("POCKET_AGENT_TOKEN", "secret"),
            ("POCKET_AGENT_BIND_ADDR", "0.0.0.0:8787"),
            ("POCKET_AGENT_ALLOW_REMOTE", "true"),
        ]);
        assert!(allowed.is_ok());
    }

    #[test]
    fn codex_target_must_be_a_loopback_websocket() {
        for target in [
            "wss://127.0.0.1:8765",
            "ws://192.0.2.1:8765",
            "ws://localhost:8765",
            "ws://127.0.0.1:8765/path",
            "ws://user:password@127.0.0.1:8765",
        ] {
            let error = config(&[
                ("POCKET_AGENT_TOKEN", "secret"),
                ("POCKET_AGENT_CODEX_URL", target),
            ])
            .unwrap_err();
            assert_eq!(error, ConfigError::UnsafeCodexUrl);
        }
    }
}
