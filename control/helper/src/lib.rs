//! What `mio-control-helper` does for each command. It runs as root through pkexec, so:
//!
//! - commands come only from [`Command::parse`]: no paths, program names or shell words from the panel;
//! - secrets arrive on stdin and are never printed, logged or put in argv or the environment;
//! - files are written atomically with a `.bak` copy, keeping their owner and mode;
//! - the gateway checks its own file (`mio-gateway kontrollera-konfiguration`) before it is written.
//!
//! Programs and HTTP go through [`System`] so the tests can run against a temporary root.

use std::path::{Path, PathBuf};
use std::time::Duration;

use mio_control_core::atomic::write_atomic;
use mio_control_core::command::{Command, UPDATE_TIMER};
use mio_control_core::env_file::{EnvFile, is_valid_value};
use mio_control_core::http::{HttpError, Response};
use mio_control_core::settings::{
    SettingsFile, VOCABULARY_PATH, check_transcription_value, is_secret_key, vocabulary_is_writable,
};
use mio_control_core::token::fresh_token;
use serde_json::{Map, Value, json};

pub const SYSTEMCTL: &str = "/usr/bin/systemctl";
pub const TAILSCALE: &str = "/usr/bin/tailscale";
pub const GATEWAY: &str = "/opt/mio-gateway/mio-gateway";
pub const UPDATE_MODEL: &str = "/opt/mio-transcription/update-model.sh";

/// Largest stdin the helper reads: settings, a key or the vocabulary.
pub const MAX_INPUT: usize = 256 * 1024;

pub struct Output {
    pub success: bool,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// Runs one of the fixed programs above. Arguments are separate words, never a shell line.
pub trait Runner {
    fn run(&self, program: &str, arguments: &[&str], stdin: Option<&[u8]>) -> std::io::Result<Output>;
}

/// Loopback HTTP GET: `(port, path, bearer, account)`. The bearer token goes only to a port that
/// `account` alone listens on.
pub type HttpGet<'a> = &'a dyn Fn(u16, &str, Option<&str>, &str) -> Result<Response, HttpError>;

pub struct System<'a> {
    /// `/` in production; a temporary directory in tests.
    pub root: PathBuf,
    pub runner: &'a dyn Runner,
    pub http: HttpGet<'a>,
}

/// The real system: programs run with a clean environment and no stdin unless given.
pub struct SystemRunner;

impl Runner for SystemRunner {
    fn run(&self, program: &str, arguments: &[&str], stdin: Option<&[u8]>) -> std::io::Result<Output> {
        use std::io::Write as _;
        use std::process::Stdio;
        let mut child = std::process::Command::new(program)
            .args(arguments)
            .env_clear()
            .env("PATH", "/usr/local/sbin:/usr/local/bin:/usr/bin")
            .env("LANG", "C.UTF-8")
            .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        if let (Some(input), Some(mut pipe)) = (stdin, child.stdin.take()) {
            pipe.write_all(input)?;
        }
        let output = child.wait_with_output()?;
        Ok(Output { success: output.status.success(), stdout: output.stdout, stderr: output.stderr })
    }
}

pub fn real_http(port: u16, path: &str, bearer: Option<&str>, account: &str) -> Result<Response, HttpError> {
    // The status group needs no password: without this check, a program running as the user
    // could listen on a stopped service's port and receive its token.
    if bearer.is_some() && !mio_control_core::socket_owner::port_owned_by(port, account) {
        return Err(HttpError::Untrusted);
    }
    mio_control_core::http::get(port, path, bearer, Duration::from_secs(5))
}

type Answer = Result<Vec<u8>, String>;

impl System<'_> {
    fn path(&self, relative: &str) -> PathBuf {
        self.root.join(relative)
    }

    fn read_env(&self, file: SettingsFile) -> Result<EnvFile, String> {
        match std::fs::read(self.path(file.path())) {
            Ok(bytes) => Ok(EnvFile::parse(&bytes)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Err(not_installed(file).to_owned()),
            Err(_) => Err("Kunde inte läsa inställningarna.".to_owned()),
        }
    }

    fn write_env(&self, file: SettingsFile, env: &EnvFile) -> Result<(), String> {
        write_atomic(&self.path(file.path()), &env.to_bytes(), 0o600).map_err(|_| "Kunde inte spara inställningarna.".to_owned())
    }

    fn run(&self, program: &str, arguments: &[&str], stdin: Option<&[u8]>) -> Result<Output, String> {
        self.runner.run(program, arguments, stdin).map_err(|_| format!("Kunde inte köra {}.", short_name(program)))
    }

    /// Asks the installed gateway whether it would start with `contents`. `strict` also requires
    /// every task to have a reviewed model and its provider's key (the panel's lock against
    /// saving an unreviewed pair).
    fn check_gateway(&self, contents: &[u8], strict: bool) -> Result<Value, String> {
        if !self.path(GATEWAY.trim_start_matches('/')).exists() && self.root == Path::new("/") {
            return Err("AI-gatewayen är inte installerad. Kör server/install.sh först.".to_owned());
        }
        let output = self.run(GATEWAY, &["kontrollera-konfiguration"], Some(contents))?;
        let answer: Option<Value> = serde_json::from_slice(&output.stdout).ok();
        if output.success {
            return answer.ok_or_else(|| "Gatewayen gav ett oväntat svar.".to_owned());
        }
        match answer {
            Some(answer) if !strict => Ok(answer),
            Some(_) => Err("Valet saknar en granskad modell eller leverantörens nyckel. Inget sparades.".to_owned()),
            // The gateway's own message names the setting, never its value.
            None => Err(gateway_message(&output.stderr)),
        }
    }
}

fn short_name(program: &str) -> &str {
    program.rsplit('/').next().unwrap_or(program)
}

fn not_installed(file: SettingsFile) -> &'static str {
    match file {
        SettingsFile::Gateway => "AI-gatewayen är inte installerad. Kör server/install.sh först.",
        SettingsFile::Transcription => "Pianissimo är inte installerat. Kör transcription-server/install.sh först.",
    }
}

fn gateway_message(stderr: &[u8]) -> String {
    let text = String::from_utf8_lossy(stderr);
    // A gateway installed before 2026-11-17 lacks the check; it must be reinstalled first.
    if text.contains("Okänt kommando") {
        return "Gatewayen på datorn är för gammal för panelen. Kör server/install.sh och försök igen. Inget sparades.".to_owned();
    }
    let line = text.lines().find(|line| !line.trim().is_empty()).unwrap_or("Gatewayen godkände inte inställningarna.");
    let line = line.strip_prefix("FEL: ").unwrap_or(line);
    format!("Gatewayen godkände inte inställningarna: {line} Inget sparades.")
}

fn json_bytes(value: &Value) -> Vec<u8> {
    let mut bytes = serde_json::to_vec(value).unwrap_or_default();
    bytes.push(b'\n');
    bytes
}

/// A provider key as pasted: one line of printable ASCII without spaces.
fn provider_key(input: &[u8]) -> Result<String, String> {
    let text = std::str::from_utf8(input).map_err(|_| "Nyckeln måste vara text.".to_owned())?;
    let key = text.strip_suffix('\n').unwrap_or(text);
    let key = key.strip_suffix('\r').unwrap_or(key).trim();
    if key.is_empty() || key.len() > 512 || !key.bytes().all(|byte| byte.is_ascii_graphic()) {
        return Err("Nyckeln ser inte ut som en API-nyckel (en rad utan mellanslag).".to_owned());
    }
    Ok(key.to_owned())
}

/// Runs `command`. `Ok` is what the helper prints on stdout.
pub fn execute(system: &System, command: &Command, stdin: &[u8]) -> Answer {
    match command {
        Command::ReadSettings(file) => read_settings(system, *file),
        Command::ReadGatewayStatus => gateway_status(system),
        Command::ReadPianissimoHealth => pianissimo_health(system),
        Command::ReadVocabulary => match std::fs::read(system.path(VOCABULARY_PATH)) {
            Ok(bytes) => Ok(bytes),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
            Err(_) => Err("Kunde inte läsa ordlistan.".to_owned()),
        },
        Command::WriteSettings(file) => write_settings(system, *file, stdin),
        Command::WriteSecret(key) => {
            let value = provider_key(stdin)?;
            let mut env = system.read_env(SettingsFile::Gateway)?;
            if env.get(SettingsFile::Gateway.token_key()).as_deref() == Some(value.as_str()) {
                return Err("Nyckeln får inte vara samma som gatewayens token.".to_owned());
            }
            env.set(key, &value).map_err(|error| error.to_string())?;
            system.check_gateway(&env.to_bytes(), false)?;
            system.write_env(SettingsFile::Gateway, &env)?;
            Ok(json_bytes(&json!({ "saved": key })))
        }
        Command::RotateToken(file) => {
            let mut env = system.read_env(*file)?;
            let token = fresh_token().map_err(|_| "Kunde inte skapa en slumpad token.".to_owned())?;
            env.set(file.token_key(), &token).map_err(|error| error.to_string())?;
            if *file == SettingsFile::Gateway {
                system.check_gateway(&env.to_bytes(), false)?;
            }
            system.write_env(*file, &env)?;
            Ok(json_bytes(&json!({ "rotated": file.token_key() })))
        }
        Command::WriteVocabulary => {
            let text = vocabulary_is_writable(stdin)?;
            let path = system.path(VOCABULARY_PATH);
            if !path.exists() {
                return Err(not_installed(SettingsFile::Transcription).to_owned());
            }
            write_atomic(&path, text.as_bytes(), 0o640).map_err(|_| "Kunde inte spara ordlistan.".to_owned())?;
            Ok(json_bytes(&json!({ "saved": "ordlista" })))
        }
        Command::Unit(action, unit) => run_checked(system, SYSTEMCTL, &[action.verb(), unit.name()]),
        Command::UpdateTimer(on) => {
            let verb = if *on { "enable" } else { "disable" };
            run_checked(system, SYSTEMCTL, &[verb, "--now", UPDATE_TIMER])
        }
        Command::UpdateModel => run_checked(system, UPDATE_MODEL, &[]),
        Command::SetupServe => setup_serve(system),
        Command::TrialModel { provider, model } => trial_model(system, provider, model),
        Command::PairingData => pairing_data(system),
    }
}

fn run_checked(system: &System, program: &str, arguments: &[&str]) -> Answer {
    let output = system.run(program, arguments, None)?;
    let mut text = output.stdout;
    text.extend_from_slice(&output.stderr);
    if output.success {
        Ok(text)
    } else {
        Err(format!("{} misslyckades:\n{}", short_name(program), String::from_utf8_lossy(&text).trim()))
    }
}

fn read_settings(system: &System, file: SettingsFile) -> Answer {
    let env = match system.read_env(file) {
        Ok(env) => env,
        Err(_) if !system.path(file.path()).exists() => return Ok(json_bytes(&json!({ "exists": false }))),
        Err(message) => return Err(message),
    };
    let (mut values, mut secrets) = (Map::new(), Map::new());
    for key in env.keys() {
        let value = env.get(&key).unwrap_or_default();
        if is_secret_key(&key) {
            // Only whether it is set: the value never leaves the helper.
            secrets.insert(key, Value::Bool(!value.is_empty()));
        } else {
            values.insert(key, Value::String(value));
        }
    }
    Ok(json_bytes(&json!({ "exists": true, "values": values, "secrets": secrets })))
}

fn gateway_status(system: &System) -> Answer {
    let env = system.read_env(SettingsFile::Gateway)?;
    let port = env.get("PORT").and_then(|port| port.parse::<u16>().ok()).unwrap_or(8_787);
    let token = env.get(SettingsFile::Gateway.token_key()).unwrap_or_default();
    Ok(http_answer((system.http)(port, "/v2/status", Some(&token), "mio-gateway")))
}

fn http_answer(result: Result<Response, HttpError>) -> Vec<u8> {
    match result {
        Ok(response) => {
            let body: Value = serde_json::from_slice(&response.body).unwrap_or(Value::Null);
            json_bytes(&json!({ "httpStatus": response.status, "body": body }))
        }
        Err(error) => json_bytes(&json!({ "httpStatus": Value::Null, "error": error.to_string() })),
    }
}

/// Pianissimo listens on 127.0.0.1:8765 (its systemd unit) and wants its token for `/health`.
fn pianissimo_health(system: &System) -> Answer {
    let env = system.read_env(SettingsFile::Transcription)?;
    let token = env.get(SettingsFile::Transcription.token_key()).unwrap_or_default();
    Ok(http_answer((system.http)(8_765, "/health", Some(&token), "mio-transcription")))
}

/// `{"set": {KEY: value}, "remove": [KEY]}` with keys from the file's writable list only.
fn write_settings(system: &System, file: SettingsFile, stdin: &[u8]) -> Answer {
    let request: Value = serde_json::from_slice(stdin).map_err(|_| "Ogiltig ändring.".to_owned())?;
    let allowed = |key: &str| file.writable_keys().contains(&key);
    let set = request.get("set").and_then(Value::as_object).cloned().unwrap_or_default();
    let remove: Vec<String> = match request.get("remove") {
        None => Vec::new(),
        Some(Value::Array(keys)) => keys.iter().map(|key| key.as_str().map(str::to_owned)).collect::<Option<_>>().ok_or("Ogiltig ändring.")?,
        Some(_) => return Err("Ogiltig ändring.".to_owned()),
    };
    if request.as_object().is_none_or(|object| object.keys().any(|key| key != "set" && key != "remove")) {
        return Err("Ogiltig ändring.".to_owned());
    }
    let mut env = system.read_env(file)?;
    let mut changed = Vec::new();
    for (key, value) in &set {
        let value = value.as_str().ok_or("Ogiltig ändring.")?;
        if !allowed(key) {
            return Err(format!("{key} går inte att ändra från panelen."));
        }
        if !is_valid_value(value) {
            return Err(format!("Ogiltigt värde för {key}."));
        }
        if file == SettingsFile::Transcription {
            check_transcription_value(key, value)?;
        }
        env.set(key, value).map_err(|error| error.to_string())?;
        changed.push(key.clone());
    }
    for key in &remove {
        if !allowed(key) || set.contains_key(key) {
            return Err(format!("{key} går inte att ta bort från panelen."));
        }
        if env.remove(key) {
            changed.push(key.clone());
        }
    }
    let check = match file {
        SettingsFile::Gateway => system.check_gateway(&env.to_bytes(), true)?,
        SettingsFile::Transcription => Value::Null,
    };
    if !changed.is_empty() {
        system.write_env(file, &env)?;
    }
    Ok(json_bytes(&json!({ "changed": changed, "check": check })))
}

/// The installers' `tailscale serve` setup: Pianissimo on 443, the gateway on 8443. Like
/// `transcription-server/install.sh`, it does not replace a 443 mapping that serves something
/// else, and it never turns on funnel.
fn setup_serve(system: &System) -> Answer {
    let gateway_port = system
        .read_env(SettingsFile::Gateway)
        .ok()
        .and_then(|env| env.get("PORT"))
        .and_then(|port| port.parse::<u16>().ok())
        .unwrap_or(8_787);
    let status = system.run(TAILSCALE, &["serve", "status"], None)?;
    let current = String::from_utf8_lossy(&status.stdout).into_owned();
    let mut output = Vec::new();
    if system.path(SettingsFile::Transcription.path()).exists() {
        if serve_target(&current, 443).is_some_and(|target| target != "http://127.0.0.1:8765") {
            return Err("Tailscale serve används redan för något annat på port 443. Inget ändrades.".to_owned());
        }
        output.extend(run_checked(system, TAILSCALE, &["serve", "--bg", "http://127.0.0.1:8765"])?);
    }
    if system.path(SettingsFile::Gateway.path()).exists() {
        let target = format!("http://127.0.0.1:{gateway_port}");
        output.extend(run_checked(system, TAILSCALE, &["serve", "--bg", "--https=8443", &target])?);
    }
    Ok(output)
}

/// Runs the gateway's trial with the root-only `gateway.env` on stdin. When all three tasks pass
/// and the pair is a candidate, it is added to `MIO_APPROVED_CANDIDATES`, the only way that
/// setting is written (user's choice 2026-11-17: a passed test is the approval).
fn trial_model(system: &System, provider: &str, model: &str) -> Answer {
    let path = system.path(SettingsFile::Gateway.path());
    let contents = std::fs::read(&path).map_err(|_| not_installed(SettingsFile::Gateway).to_owned())?;
    let output = system.run(GATEWAY, &["prova", provider, model], Some(&contents))?;
    if !output.stdout.starts_with(b"{") {
        return Err(gateway_message(&output.stderr));
    }
    if output.success {
        let catalog = system.run(GATEWAY, &["granskade-modeller"], None)?;
        let catalog: Value = serde_json::from_slice(&catalog.stdout).unwrap_or(Value::Null);
        let candidate = catalog.get("candidates").and_then(Value::as_array).is_some_and(|candidates| {
            candidates.iter().any(|entry| entry["provider"] == provider && entry["model"] == model)
        });
        if candidate {
            let mut env = EnvFile::parse(&contents);
            let entry = format!("{provider}={model}");
            let mut approved: Vec<String> = env.get("MIO_APPROVED_CANDIDATES").unwrap_or_default()
                .split(',').map(str::trim).filter(|item| !item.is_empty()).map(str::to_owned).collect();
            if !approved.contains(&entry) {
                approved.push(entry);
                env.set("MIO_APPROVED_CANDIDATES", &approved.join(",")).map_err(|error| error.to_string())?;
                system.check_gateway(&env.to_bytes(), false)?;
                system.write_env(SettingsFile::Gateway, &env)?;
            }
        }
    }
    // The trial's own answer, passed or not: synthetic text only, no key.
    Ok(output.stdout)
}

/// What `tailscale serve status` proxies the root path of HTTPS `port` to, if anything:
///
/// ```text
/// https://dator.tail1234.ts.net (tailnet only)
/// |-- / proxy http://127.0.0.1:8765
/// ```
pub fn serve_target(status: &str, port: u16) -> Option<String> {
    let mut in_block = false;
    for line in status.lines().map(str::trim) {
        if let Some(rest) = line.strip_prefix("https://") {
            let host = rest.split_whitespace().next().unwrap_or("");
            let block_port = host.rsplit_once(':').and_then(|(_, port)| port.parse::<u16>().ok()).unwrap_or(443);
            in_block = block_port == port;
        } else if in_block && let Some(target) = line.strip_prefix("|-- / proxy ") {
            return Some(target.trim().to_owned());
        } else if line.is_empty() {
            in_block = false;
        }
    }
    None
}

fn pairing_data(system: &System) -> Answer {
    let gateway = std::fs::read(system.path(SettingsFile::Gateway.path()))
        .map_err(|_| not_installed(SettingsFile::Gateway).to_owned())?;
    let mut files = gateway;
    if let Ok(transcription) = std::fs::read(system.path(SettingsFile::Transcription.path())) {
        files.push(b'\n');
        files.extend(transcription);
    }
    let status = system.run(TAILSCALE, &["status", "--json"], None)?;
    if !status.success {
        return Err("Tailscale är inte inloggat.".to_owned());
    }
    let host = system.run(GATEWAY, &["tailscale-host"], Some(&status.stdout))?;
    let host = String::from_utf8_lossy(&host.stdout).trim().to_owned();
    let valid_host = host.split('.').count() >= 2
        && host.split('.').all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-'));
    if !valid_host {
        return Err("Hittar inte datorns Tailscale-namn. Är MagicDNS och HTTPS på i Tailscale?".to_owned());
    }
    let payload = system.run(GATEWAY, &["pairing-payload", &host], Some(&files))?;
    if !payload.success {
        return Err("Hittar ingen gatewaytoken. Kör server/install.sh först.".to_owned());
    }
    Ok(payload.stdout)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serve_status_blocks_are_read_per_port() {
        let both = "https://dator.tail1234.ts.net (tailnet only)\n|-- / proxy http://127.0.0.1:8765\n\nhttps://dator.tail1234.ts.net:8443 (tailnet only)\n|-- / proxy http://127.0.0.1:8787\n";
        assert_eq!(serve_target(both, 443).as_deref(), Some("http://127.0.0.1:8765"));
        assert_eq!(serve_target(both, 8443).as_deref(), Some("http://127.0.0.1:8787"));
        assert_eq!(serve_target("No serve config\n", 443), None);
        assert_eq!(serve_target("https://dator.ts.net (tailnet only)\n|-- / proxy http://127.0.0.1:3000\n", 443).as_deref(), Some("http://127.0.0.1:3000"));
    }

    #[test]
    fn a_pasted_key_loses_its_line_end_and_nothing_else() {
        assert_eq!(provider_key(b"gsk_abc123\n").unwrap(), "gsk_abc123");
        assert_eq!(provider_key(b"gsk_abc123\r\n").unwrap(), "gsk_abc123");
        for bad in [&b""[..], b"\n", b"two words", b"\xff", b"line\nbreak"] {
            assert!(provider_key(bad).is_err(), "{bad:?}");
        }
    }
}
