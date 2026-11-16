use std::process::ExitCode;
use std::sync::Arc;

use mio_gateway::config::load_config;
use mio_gateway::server::Gateway;
use mio_gateway::state_store::FileCounterStore;
use mio_gateway::transport::HttpsTransport;
use tokio::signal::unix::{SignalKind, signal};

fn serve() -> Result<(), &'static str> {
    const CONFIGURATION: &str = "Mio-servern är avstängd: kontrollera serverns miljövariabler enligt README.";
    const START: &str = "Mio-servern kunde inte starta. Kontrollera port och inställningar.";
    let config = load_config(&|name| std::env::var(name).ok()).map_err(|_| CONFIGURATION)?;
    let port = config.port;
    let mut gateway = Gateway::new(config, Arc::new(HttpsTransport::new().map_err(|_| START)?)).map_err(|_| CONFIGURATION)?;
    // MIO_STATE_FILE keeps the daily counters across restarts (set by the systemd unit).
    if let Some(path) = std::env::var_os("MIO_STATE_FILE").filter(|path| !path.is_empty()) {
        gateway = gateway.with_store(Arc::new(FileCounterStore::new(path)));
    }
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|_| START)?;
    runtime.block_on(async {
        // HTTPS terminates at the local reverse proxy. Never expose this HTTP listener publicly.
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", port)).await.map_err(|_| START)?;
        let (mut interrupt, mut terminate) = (signal(SignalKind::interrupt()).map_err(|_| START)?,
            signal(SignalKind::terminate()).map_err(|_| START)?);
        println!("Mio-servern kör på loopback bakom din HTTPS-proxy.");
        // Stopping drops every open request; the counters were saved when each was reserved.
        tokio::select! {
            () = gateway.serve(listener) => {}
            _ = interrupt.recv() => {}
            _ = terminate.recv() => {}
        }
        Ok(())
    })
}

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let outcome = match mio_gateway::tools::run(&arguments) {
        Some(outcome) => outcome.map_err(|message| format!("FEL: {message}")),
        None if arguments.is_empty() => serve().map_err(str::to_owned),
        None => Err("FEL: Okänt kommando.".to_owned()),
    };
    match outcome {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}
