//! Small helpers for `install.sh` and `mio-pair`, so the PC needs no other runtime. Secrets
//! arrive on standard input and leave on standard output or into a root-only file: never
//! through arguments, the environment or logs.

use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;

use serde_json::{Value, json};

use crate::config::is_gateway_token;

/// The value of `NAME=value` on its own line, when it has the shape of a Mio token. A file
/// saved with Windows line ends still yields its token (ultrareview C3).
fn token_in<'a>(text: &'a str, name: &str) -> Option<&'a str> {
    text.split('\n').map(|line| line.strip_suffix('\r').unwrap_or(line))
        .filter_map(|line| line.strip_prefix(name)?.strip_prefix('='))
        .find(|value| (32..=256).contains(&value.len()) && value.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"_-".contains(&byte)))
}

fn base64url(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut encoded = String::new();
    for group in bytes.chunks(3) {
        let bits = group.iter().fold(0u32, |bits, byte| (bits << 8) | u32::from(*byte)) << (8 * (3 - group.len()));
        for index in 0..=group.len() {
            encoded.push(ALPHABET[(bits >> (18 - 6 * index) & 63) as usize] as char);
        }
    }
    encoded
}

/// The contents of `gateway.env`. A file with a gateway token is a key rotation: only the
/// `GROQ_API_KEY` line changes and every other line (limits, port, task profiles, the token) is
/// kept, so the phone needs no re-pairing (ultrareview C2). Lines are compared as bytes, so
/// non-UTF-8 text survives; Windows line ends become plain ones. Anything else gets a new file.
pub fn gateway_env(key: &str, existing: Option<&[u8]>, model: &str, port: &str, fresh_token: &str) -> Vec<u8> {
    match existing {
        Some(existing) if token_in(&String::from_utf8_lossy(existing), "MIO_GATEWAY_TOKEN").is_some() => rotate_key(existing, key),
        _ => fresh_env(key, model, port, fresh_token).into_bytes(),
    }
}

fn rotate_key(existing: &[u8], key: &str) -> Vec<u8> {
    let assignment = format!("GROQ_API_KEY={key}");
    let mut contents = Vec::with_capacity(existing.len() + assignment.len());
    let mut replaced = false;
    let body = existing.strip_suffix(b"\n").unwrap_or(existing);
    for line in body.split(|byte| *byte == b'\n') {
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        if line.starts_with(b"GROQ_API_KEY=") {
            if replaced {
                continue;
            }
            contents.extend_from_slice(assignment.as_bytes());
            replaced = true;
        } else {
            contents.extend_from_slice(line);
        }
        contents.push(b'\n');
    }
    if !replaced {
        contents.extend_from_slice(assignment.as_bytes());
        contents.push(b'\n');
    }
    contents
}

fn fresh_env(key: &str, model: &str, port: &str, token: &str) -> String {
    [
        "# Mio gateway. Skapad av install.sh. Dela aldrig denna fil.".to_owned(),
        format!("GROQ_API_KEY={key}"), format!("MIO_GATEWAY_TOKEN={token}"),
        "MIO_AI_PROVIDER=groq".to_owned(), format!("MIO_AI_MODEL={model}"),
        // Groq free tier for this model: 30 RPM, 8,000 TPM, 200,000 tokens/day. The gateway sizes each
        // request to the tokens-per-minute budget; the daily cap leaves a margin.
        "MIO_REQUESTS_PER_MINUTE=10".to_owned(), "MIO_TOKENS_PER_MINUTE=8000".to_owned(),
        "MIO_TOKENS_PER_DAY=190000".to_owned(), "MIO_REQUESTS_PER_DAY=".to_owned(),
        "MIO_LESSON_INTERVAL_SECONDS=60".to_owned(), format!("PORT={port}"), String::new(),
    ].join("\n")
}

/// The computer's Tailscale name from `tailscale status --json`, without the trailing dot.
pub fn tailscale_host(status: &str) -> String {
    let name = serde_json::from_str::<Value>(status).ok()
        .and_then(|status| status.get("Self")?.get("DNSName")?.as_str().map(str::to_owned)).unwrap_or_default();
    name.strip_suffix('.').unwrap_or(&name).to_owned()
}

/// The compact JSON inside the pairing QR code, or `None` without a gateway token.
pub fn pairing_payload(env_files: &str, host: &str) -> Option<String> {
    let ai = token_in(env_files, "MIO_GATEWAY_TOKEN")?;
    let transcription = token_in(env_files, "MIO_TRANSCRIPTION_TOKEN");
    Some(json!({ "mio": 1, "aiURL": format!("https://{host}:8443"), "aiToken": ai,
        "transcriptionURL": transcription.map(|_| format!("https://{host}")), "transcriptionToken": transcription }).to_string())
}

/// The pairing values as text, for typing them in by hand.
pub fn pairing_text(payload: &str) -> Option<String> {
    let payload: Value = serde_json::from_str(payload).ok()?;
    let field = |name: &str| payload.get(name).and_then(Value::as_str);
    let mut text = format!("AI-adress: {}\nAI-token: {}\n", field("aiURL")?, field("aiToken")?);
    if let (Some(url), Some(token)) = (field("transcriptionURL"), field("transcriptionToken")) {
        text.push_str(&format!("Transkriptionsadress: {url}\nTranskriptionstoken: {token}\n"));
    }
    Some(text)
}

/// Standard input as text; bytes that are not UTF-8 (a Latin-1 comment) do not fail the read.
fn standard_input() -> Result<String, String> {
    let mut bytes = Vec::new();
    std::io::Read::read_to_end(&mut std::io::stdin(), &mut bytes).map_err(|_| "Kunde inte läsa standard in.".to_owned())?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn write_config(path: &str, model: &str, port: &str) -> Result<(), String> {
    let key = standard_input()?;
    let mut random = [0u8; 32];
    getrandom::fill(&mut random).map_err(|_| "Kunde inte skapa en slumpad token.".to_owned())?;
    let fresh = base64url(&random);
    debug_assert!(is_gateway_token(&fresh));
    let contents = gateway_env(&key, std::fs::read(path).ok().as_deref(), model, port, &fresh);
    let temporary = format!("{path}.tmp");
    let failed = |_| "Kunde inte skriva konfigurationen.".to_owned();
    let mut file = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&temporary).map_err(failed)?;
    file.write_all(&contents).map_err(failed)?;
    drop(file);
    std::fs::rename(&temporary, path).map_err(failed)
}

/// Runs a helper command. Returns `None` when `arguments` name no helper.
pub fn run(arguments: &[String]) -> Option<Result<(), String>> {
    let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
    let print = |text: String| { print!("{text}"); Ok(()) };
    Some(match arguments.as_slice() {
        ["write-config", path, model, port] => write_config(path, model, port),
        ["tailscale-host"] => standard_input().and_then(|status| print(tailscale_host(&status))),
        ["pairing-payload", host] => standard_input().and_then(|text| pairing_payload(&text, host)
            .ok_or_else(|| "Hittar ingen gatewaytoken. Kör server/install.sh först.".to_owned()).and_then(print)),
        ["pairing-text"] => standard_input().and_then(|payload| pairing_text(&payload)
            .ok_or_else(|| "Ogiltig parningskod.".to_owned()).and_then(print)),
        _ => return None,
    })
}
