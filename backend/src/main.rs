use pocket_agent_gateway::{AppState, Config, app_server, ensure_codex_available, router};
use tokio::net::TcpListener;
use tracing::{error, info, warn};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("pocket_agent_gateway=info,tower_http=info")),
        )
        .init();

    let config = Config::from_env()?;
    let state = AppState::new(config);

    if let Err(error) = ensure_codex_available(&state).await {
        warn!(%error, "Codex app-server is not ready; the gateway will still serve health and static routes");
    }

    let listener = TcpListener::bind(state.config.bind_addr).await?;
    let local_addr = listener.local_addr()?;
    info!(%local_addr, "Pocket Agent gateway listening");

    let serve_result = axum::serve(listener, router(state.clone()))
        .with_graceful_shutdown(shutdown_signal(state.clone()))
        .await;

    app_server::stop_managed_codex(&state).await;
    if let Err(error) = serve_result {
        error!(%error, "gateway server failed");
        return Err(error.into());
    }
    Ok(())
}

async fn shutdown_signal(state: AppState) {
    let ctrl_c = async {
        if let Err(error) = tokio::signal::ctrl_c().await {
            error!(%error, "failed to install Ctrl+C handler");
        }
    };

    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut signal) => {
                signal.recv().await;
            }
            Err(error) => error!(%error, "failed to install SIGTERM handler"),
        }
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        () = ctrl_c => {},
        () = terminate => {},
    }

    state.begin_shutdown();
    info!("shutdown signal received");
}
