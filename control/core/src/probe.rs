//! Fetches the status the overview shows. Every call blocks briefly, so the panel runs it on a
//! background thread. Nothing here needs a password: systemd answers over D-Bus, Tailscale and
//! `nvidia-smi` run as the user, and the token-protected answers come through the helper's
//! passwordless `status` group.

use std::process::{Command as Process, Stdio};
use std::time::Duration;

use serde_json::Value;
use zbus::blocking::Connection;
use zbus::zvariant::{OwnedObjectPath, OwnedValue};

use crate::command::{Command, UPDATE_TIMER, Unit};
use crate::helper_client::run_helper;
use crate::status::{
    GatewayStatus, GpuStatus, NVIDIA_SMI_QUERY, Overview, PianissimoHealth, TailscaleStatus, TimerStatus, UnitState,
};

const SYSTEMD: &str = "org.freedesktop.systemd1";

fn property(connection: &Connection, path: &OwnedObjectPath, interface: &str, name: &str) -> Option<OwnedValue> {
    let reply = connection
        .call_method(Some(SYSTEMD), path, Some("org.freedesktop.DBus.Properties"), "Get", &(interface, name))
        .ok()?;
    reply.body().deserialize::<OwnedValue>().ok()
}

fn text(connection: &Connection, path: &OwnedObjectPath, interface: &str, name: &str) -> String {
    property(connection, path, interface, name).and_then(|value| String::try_from(value).ok()).unwrap_or_default()
}

/// The object path of a unit; `LoadUnit` answers even for units that do not exist.
fn unit_path(connection: &Connection, name: &str) -> Option<OwnedObjectPath> {
    let reply = connection
        .call_method(Some(SYSTEMD), "/org/freedesktop/systemd1", Some("org.freedesktop.systemd1.Manager"), "LoadUnit", &(name,))
        .ok()?;
    reply.body().deserialize::<OwnedObjectPath>().ok()
}

pub fn unit_state(connection: &Connection, name: &str) -> UnitState {
    let Some(path) = unit_path(connection, name) else { return UnitState::Unknown };
    let unit = "org.freedesktop.systemd1.Unit";
    UnitState::from_systemd(&text(connection, &path, unit, "LoadState"), &text(connection, &path, unit, "ActiveState"), &text(connection, &path, unit, "SubState"))
}

pub fn timer_status(connection: &Connection) -> Option<TimerStatus> {
    let timer = unit_path(connection, UPDATE_TIMER)?;
    if text(connection, &timer, "org.freedesktop.systemd1.Unit", "LoadState") == "not-found" {
        return None;
    }
    let last = property(connection, &timer, "org.freedesktop.systemd1.Timer", "LastTriggerUSec")
        .and_then(|value| u64::try_from(value).ok())
        .filter(|usec| *usec > 0);
    let service = unit_path(connection, "mio-pianissimo-update.service");
    let result = service
        .map(|path| text(connection, &path, "org.freedesktop.systemd1.Service", "Result"))
        .filter(|result| !result.is_empty());
    Some(TimerStatus {
        enabled: text(connection, &timer, "org.freedesktop.systemd1.Unit", "UnitFileState") == "enabled",
        last_run_usec: last,
        last_result: result.filter(|_| last.is_some()),
    })
}

/// Output of a user program with a time limit, or `None` if it is missing or fails.
fn program_output(program: &str, arguments: &[&str], timeout: Duration) -> Option<String> {
    let mut child = Process::new(program).args(arguments).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().ok()?;
    let deadline = std::time::Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if std::time::Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            Err(_) => return None,
        }
    }
    let output = child.wait_with_output().ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

pub fn tailscale() -> TailscaleStatus {
    let timeout = Duration::from_secs(3);
    let Some(status) = program_output("tailscale", &["status", "--json"], timeout) else {
        let installed = program_output("tailscale", &["version"], timeout).is_some();
        return TailscaleStatus { installed, ..TailscaleStatus::default() };
    };
    let status: Value = serde_json::from_str(&status).unwrap_or(Value::Null);
    let serve = program_output("tailscale", &["serve", "status", "--json"], timeout)
        .and_then(|serve| serde_json::from_str(&serve).ok())
        .unwrap_or(Value::Null);
    TailscaleStatus::parse(&status, &serve)
}

pub fn gpu() -> Option<GpuStatus> {
    let csv = program_output("nvidia-smi", &[NVIDIA_SMI_QUERY, "--format=csv,noheader,nounits"], Duration::from_secs(3))?;
    GpuStatus::parse(&csv)
}

/// `GET /health` on the gateway needs no token.
pub fn gateway_health(port: u16) -> Option<bool> {
    match crate::http::get(port, "/health", None, Duration::from_secs(2)) {
        Ok(response) => Some(response.status == 200),
        Err(_) => Some(false),
    }
}

/// `{"httpStatus": …, "body": …}` from the helper's status commands.
fn helper_body(command: &Command) -> Option<Value> {
    let answer: Value = serde_json::from_slice(&run_helper(command, None).ok()?).ok()?;
    answer.get("httpStatus").and_then(Value::as_u64)?;
    answer.get("body").cloned()
}

/// Reads everything once. `previous` supplies what a failed read leaves as it was.
pub fn overview(gateway_port: u16, previous: &Overview) -> Overview {
    let connection = Connection::system().ok();
    let units = |unit: Unit| connection.as_ref().map_or(UnitState::Unknown, |connection| unit_state(connection, unit.name()));
    let gateway_unit = units(Unit::Gateway);
    let transcription_unit = units(Unit::Transcription);
    let gateway_running = gateway_unit == UnitState::Running;
    let transcription_running = transcription_unit == UnitState::Running;
    Overview {
        gateway_health: if gateway_running { gateway_health(gateway_port) } else { None },
        gateway: gateway_running
            .then(|| helper_body(&Command::ReadGatewayStatus).map(|body| GatewayStatus::parse(&body)))
            .flatten()
            .or_else(|| previous.gateway.clone().filter(|_| gateway_running)),
        pianissimo: transcription_running.then(|| helper_body(&Command::ReadPianissimoHealth).and_then(|body| PianissimoHealth::parse(&body))).flatten(),
        tailscale: Some(tailscale()),
        gpu: gpu(),
        update_timer: connection.as_ref().and_then(timer_status),
        gateway_unit,
        transcription_unit,
    }
}
