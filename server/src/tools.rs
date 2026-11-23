//! Small helpers for `install.sh` and `mio-pair`, so the PC needs no other runtime. Secrets
//! arrive on standard input and leave on standard output or into a root-only file: never
//! through arguments, the environment or logs.

use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;

use serde_json::{Value, json};

use crate::config::{is_gateway_token, load_config, looks_like_provider_key};
use crate::generation::{Transport, trial_call};
use crate::tasks::Mode;
use crate::model_profiles::{CANDIDATE_MODELS, PROVIDERS, REASONING_TASK, REVIEWED_MODELS, Reviewed, price, provider, reasoning_levels};
use crate::task_profiles::{TASK_IDS, resolve_task_profile, task_configuration_identifiers};

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
/// A kept token that starts like a provider key (which the phone refuses) is replaced too.
pub fn gateway_env(key: &str, existing: Option<&[u8]>, model: &str, port: &str, fresh_token: &str) -> Vec<u8> {
    let kept = existing.and_then(|existing| token_in(&String::from_utf8_lossy(existing), "MIO_GATEWAY_TOKEN").map(str::to_owned));
    match (existing, kept) {
        (Some(existing), Some(token)) => {
            let contents = rotate_key(existing, key, "GROQ_API_KEY");
            if is_gateway_token(&token) { contents } else { rotate_key(&contents, fresh_token, "MIO_GATEWAY_TOKEN") }
        }
        _ => fresh_env(key, model, port, fresh_token).into_bytes(),
    }
}

/// The Mistral models `install.sh` sets up (user decisions 2026-11-19 and 2026-11-20): Small 4
/// with reasoning off for `ask` and `everyday`, Large 4 at medium reasoning for `lesson` only.
pub const MISTRAL_DEFAULT_MODEL: &str = "mistral-small-2603";
pub const MISTRAL_LESSON_MODEL: &str = "mistral-large-4-0";

/// `gateway.env` for Mistral. A file that already has a gateway token keeps everything,
/// provider choice included, and only gets its `MISTRAL_API_KEY` line set: an existing Groq
/// installation stays on Groq with the same token (no re-pairing) and switches to Mistral in
/// Mio Kontroll. Anything else gets a new Mistral file. Neither approves a candidate: that line
/// is only written after a passed `mio-gateway prova` (by install.sh or the panel's helper).
pub fn mistral_gateway_env(key: &str, existing: Option<&[u8]>, port: &str, fresh_token: &str) -> Vec<u8> {
    let kept = existing.and_then(|existing| token_in(&String::from_utf8_lossy(existing), "MIO_GATEWAY_TOKEN").map(str::to_owned));
    match (existing, kept) {
        (Some(existing), Some(token)) => {
            let contents = rotate_key(existing, key, "MISTRAL_API_KEY");
            if is_gateway_token(&token) { contents } else { rotate_key(&contents, fresh_token, "MIO_GATEWAY_TOKEN") }
        }
        _ => [
            "# Mio gateway. Skapad av install.sh. Dela aldrig denna fil.".to_owned(),
            format!("MISTRAL_API_KEY={key}"), format!("MIO_GATEWAY_TOKEN={fresh_token}"),
            "MIO_AI_PROVIDER=mistral".to_owned(), format!("MIO_AI_MODEL={MISTRAL_DEFAULT_MODEL}"),
            // Raw JSON, as Mio Kontroll writes it; only lessons may reason.
            format!("MIO_AI_TASK_PROFILES={{\"lesson\":{{\"model\":\"{MISTRAL_LESSON_MODEL}\"}}}}"),
            // Mistral has no per-minute token reservation like Groq's free tier, so no budget is
            // set for it. MIO_TOKENS_PER_MINUTE is Groq's and only applies if Groq is chosen later.
            "MIO_REQUESTS_PER_MINUTE=10".to_owned(), "MIO_TOKENS_PER_MINUTE=8000".to_owned(),
            "MIO_TOKENS_PER_MINUTE_MISTRAL=".to_owned(), "MIO_TOKENS_PER_DAY=".to_owned(), "MIO_REQUESTS_PER_DAY=".to_owned(),
            "MIO_LESSON_INTERVAL_SECONDS=60".to_owned(), format!("PORT={port}"), String::new(),
        ].join("\n").into_bytes(),
    }
}

/// Sets `name` to `value` and keeps every other line.
fn rotate_key(existing: &[u8], value: &str, name: &str) -> Vec<u8> {
    let assignment = format!("{name}={value}");
    let prefix = format!("{name}=");
    let mut contents = Vec::with_capacity(existing.len() + assignment.len());
    let mut replaced = false;
    let body = existing.strip_suffix(b"\n").unwrap_or(existing);
    for line in body.split(|byte| *byte == b'\n') {
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        if line.starts_with(prefix.as_bytes()) {
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

/// The variables of an environment file, read the way systemd's `EnvironmentFile=` reads them:
/// `#` and `;` start comment lines, the key and value are trimmed, and one pair of matching
/// quotes around the value is removed. A later line overrides an earlier one.
pub fn environment_file(text: &str) -> std::collections::BTreeMap<String, String> {
    let mut variables = std::collections::BTreeMap::new();
    for line in text.split('\n').map(|line| line.strip_suffix('\r').unwrap_or(line).trim()) {
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else { continue };
        let value = value.trim();
        let unquoted = ['"', '\''].iter().find_map(|quote| {
            value.strip_prefix(*quote)?.strip_suffix(*quote).filter(|_| value.len() >= 2)
        });
        variables.insert(key.trim().to_owned(), unquoted.unwrap_or(value).to_owned());
    }
    variables
}

/// Checks an environment file the way the service would load it, for the control panel. The
/// answer names providers, models and error codes only, never a key or token. `Err` when the
/// gateway would refuse to start or any task lacks a reviewed model and its provider's key.
pub fn check_configuration(text: &str) -> Result<String, String> {
    let variables = environment_file(text);
    let config = load_config(&|name| variables.get(name).cloned()).map_err(|error| error.0.to_owned())?;
    let mut complete = true;
    let tasks: Vec<Value> = TASK_IDS.iter().map(|task| {
        let (provider, model) = task_configuration_identifiers(&config, task);
        let resolved = resolve_task_profile(&config, task);
        complete &= resolved.configured;
        json!({ "task": task, "provider": provider, "model": model, "configured": resolved.configured,
            "error": resolved.configuration_error })
    }).collect();
    let answer = json!({ "valid": complete, "port": config.port, "tasks": tasks }).to_string();
    if complete { Ok(answer) } else { Err(answer) }
}

/// The reviewed provider and model pairs as JSON, with the variable that holds each key, and
/// the candidates the panel shows greyed out with why they cannot be chosen yet.
pub fn reviewed_models() -> String {
    let describe = |reviewed: &Reviewed| {
        let secret = provider(reviewed.provider).map(|provider| provider.secret_variable);
        json!({ "provider": reviewed.provider, "model": reviewed.model, "secretVariable": secret,
            "plain": reviewed.plain, "schemaDialect": reviewed.schema_dialect, "sources": reviewed.sources,
            "temperature": if reviewed.sends_zero_temperature() { "0" } else { "provider-default" },
            // A pair that always reasons may only serve lessons (user decision 2026-11-19).
            "reasoning": reviewed.reasoning.level(),
            // The levels the panel offers for lessons (MIO-44); empty when reasoning is off.
            "reasoningLevels": reasoning_levels(reviewed.provider, reviewed.model),
            "tasks": if reviewed.reasoning.reasons() { vec![REASONING_TASK] } else { TASK_IDS.to_vec() },
            // USD per million tokens from the reviewed table, or null (Groq's free tier, Haiku).
            "prices": price(reviewed.provider, reviewed.model).map(|price| json!({ "inputPerMillion": price.input,
                "cachedInputPerMillion": price.cached_input, "outputPerMillion": price.output, "asOf": price.as_of })),
            "reviewedAt": reviewed.reviewed_at, "liveTested": false, "blocked": reviewed.blocked })
    };
    let providers: Vec<&str> = PROVIDERS.iter().map(|provider| provider.id).collect();
    json!({ "providers": providers, "models": REVIEWED_MODELS.iter().map(describe).collect::<Vec<_>>(),
        "candidates": CANDIDATE_MODELS.iter().map(describe).collect::<Vec<_>>() }).to_string()
}

/// The synthetic Swedish requests `prova` sends, one per task. No user's text is ever used.
fn trial_payloads() -> [(&'static str, Mode, Value); 3] {
    const OLD: &str = "00000000-0000-0000-0000-000000000001:0";
    const NEW: &str = "00000000-0000-0000-0000-000000000002:0";
    [
        ("ask", Mode::Ask, json!({ "question": "Vad ska jag ta med till biblioteket?",
            "context": [{ "label": "Anteckning", "text": "Ta med lånekortet och boken om fotosyntes till biblioteket på torsdag." }] })),
        ("everyday", Mode::AnalyzeV2, json!({ "mode": "everyday", "timeZone": "Europe/Stockholm",
            "fragments": [{ "id": NEW, "text": "Jag måste lämna in labbrapporten i kemi senast fredag klockan 16.", "occurredAt": "2026-09-30T12:01:00Z" }],
            "contextFragments": [{ "id": OLD, "text": "Vi hade laboration om syror och baser i dag.", "occurredAt": "2026-09-30T12:00:00Z" }],
            "priorDecisions": [], "contextLimited": false })),
        ("lesson", Mode::Lesson, json!({ "mode": "lesson", "timeZone": "Europe/Stockholm", "fragments": [{ "id": OLD,
            "occurredAt": "2026-09-28T08:00:00Z",
            "text": "Procent betyder hundradelar. 20 procent av 50 är 0,20 gånger 50 = 10. Gör uppgift 7 till fredag." }] })),
    ]
}

/// `mio-gateway prova <provider> <model>`: one synthetic call per task against a reviewed pair
/// or a candidate, with the key from the environment file on stdin. Prints JSON per task;
/// `Err` unless every answer passed validation. A pair that always reasons (Mistral Large 4)
/// may only serve lessons, so it is tried on `lesson` alone. Only run when the user asks for it.
pub fn trial(text: &str, provider_id: &str, model: &str, transport: &dyn Transport) -> Result<String, String> {
    let variables = environment_file(text);
    let config = load_config(&|name| variables.get(name).cloned()).map_err(|error| error.0.to_owned())?;
    let profile = crate::model_profiles::provider_profile(provider_id, model, None)
        .ok().or_else(|| crate::model_profiles::candidate_profile(provider_id, model))
        .ok_or_else(|| "Paret är varken granskat eller kandidat.".to_owned())?;
    let key = config.provider_secrets.get(provider_id).cloned().unwrap_or_default();
    if key.trim().is_empty() {
        return Err(format!("Nyckel saknas: {}.", provider(provider_id).map_or("", |entry| entry.secret_variable)));
    }
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|_| "Kunde inte starta.".to_owned())?;
    let now = || std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as i64);
    let mut passed = true;
    let tasks: Vec<Value> = trial_payloads().into_iter()
        .filter(|(task, _, _)| !profile.reasoning.reasons() || *task == REASONING_TASK).map(|(task, mode, payload)| {
        let started = std::time::Instant::now();
        let outcome = runtime.block_on(trial_call(profile.clone(), &key, mode, &payload, transport, &now, config.minute_budget(provider_id)));
        let milliseconds = started.elapsed().as_millis() as u64;
        passed &= outcome.is_ok();
        match outcome {
            Ok((answer, normalized)) => {
                let usage = normalized.usage.unwrap_or_default();
                // Token counts only; the thinking itself was dropped in the adapter.
                json!({ "task": task, "ok": true, "error": null, "milliseconds": milliseconds, "answer": answer,
                    "inputTokens": usage.input_tokens, "outputTokens": usage.output_tokens, "reasoningTokens": usage.reasoning_tokens })
            }
            Err(error) => json!({ "task": task, "ok": false, "error": error.code, "milliseconds": milliseconds, "answer": null }),
        }
    }).collect();
    let answer = json!({ "provider": provider_id, "model": model, "passed": passed, "tasks": tasks }).to_string();
    if passed { Ok(answer) } else { Err(answer) }
}

/// Standard input as text; bytes that are not UTF-8 (a Latin-1 comment) do not fail the read.
fn standard_input() -> Result<String, String> {
    let mut bytes = Vec::new();
    std::io::Read::read_to_end(&mut std::io::stdin(), &mut bytes).map_err(|_| "Kunde inte läsa standard in.".to_owned())?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// A random token the phone accepts: about 1 in 32,000 random tokens starts like a provider
/// key and is drawn again (ultrareview D1).
fn fresh_token() -> Result<String, String> {
    loop {
        let mut random = [0u8; 32];
        getrandom::fill(&mut random).map_err(|_| "Kunde inte skapa en slumpad token.".to_owned())?;
        let token = base64url(&random);
        if !looks_like_provider_key(&token) {
            return Ok(token);
        }
    }
}

fn write_config(path: &str, provider: &str, model: &str, port: &str) -> Result<(), String> {
    let key = standard_input()?;
    let fresh = fresh_token()?;
    debug_assert!(is_gateway_token(&fresh));
    let existing = std::fs::read(path).ok();
    let contents = if provider == "mistral" {
        mistral_gateway_env(&key, existing.as_deref(), port, &fresh)
    } else {
        gateway_env(&key, existing.as_deref(), model, port, &fresh)
    };
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
        ["write-config", path, model, port] => write_config(path, "groq", model, port),
        // Mistral: a new file with Small 4 and Large 4 (lessons), or only the key line set.
        ["write-mistral-config", path, port] => write_config(path, "mistral", "", port),
        ["tailscale-host"] => standard_input().and_then(|status| print(tailscale_host(&status))),
        ["pairing-payload", host] => standard_input().and_then(|text| pairing_payload(&text, host)
            .ok_or_else(|| "Hittar ingen gatewaytoken. Kör server/install.sh först.".to_owned()).and_then(print)),
        // For the control panel: never writes anything and never prints a secret.
        ["kontrollera-konfiguration"] => standard_input().and_then(|text| match check_configuration(&text) {
            Ok(answer) => print(answer + "\n"),
            Err(answer) if answer.starts_with('{') => {
                println!("{answer}");
                Err("En uppgift saknar en granskad modell eller leverantörens nyckel.".to_owned())
            }
            Err(message) => Err(message),
        }),
        ["granskade-modeller"] => print(reviewed_models() + "\n"),
        // Real provider traffic: only from the panel's "Prova modellen", which the user presses.
        ["prova", provider_id, model] => standard_input().and_then(|text| {
            let transport = crate::transport::HttpsTransport::new().map_err(|_| "Kunde inte starta HTTPS.".to_owned())?;
            match trial(&text, provider_id, model, &transport) {
                Ok(answer) => print(answer + "\n"),
                Err(answer) if answer.starts_with('{') => {
                    println!("{answer}");
                    Err("Provet godkändes inte.".to_owned())
                }
                Err(message) => Err(message),
            }
        }),
        ["pairing-text"] => standard_input().and_then(|payload| pairing_text(&payload)
            .ok_or_else(|| "Ogiltig parningskod.".to_owned()).and_then(print)),
        _ => return None,
    })
}
