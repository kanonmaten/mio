use mio_gateway::config::load_config;
use mio_gateway::tools::{
    check_configuration, environment_file, gateway_env, pairing_payload, pairing_text, reviewed_models, tailscale_host,
};
use serde_json::{Value, json};

const TOKEN: &str = "fixture_gateway_token_01234567890123456789";
const FRESH: &str = "fresh_gateway_token_0123456789012345678901";
const KEY: &str = "gsk_fixture0123456789abcdefghij";

fn text(bytes: Vec<u8>) -> String {
    String::from_utf8(bytes).unwrap()
}

#[test]
fn the_written_configuration_loads_and_keeps_an_existing_gateway_token() {
    let fresh = text(gateway_env(KEY, None, "qwen/qwen3.8-27b", "8787", FRESH));
    assert!(fresh.starts_with("# Mio gateway.") && fresh.ends_with("PORT=8787\n"));
    assert!(fresh.contains(&format!("GROQ_API_KEY={KEY}\nMIO_GATEWAY_TOKEN={FRESH}\n")));
    // What install.sh writes is what the gateway reads: systemd passes each NAME=value line on.
    let lookup = |text: &str, name: &str| text.lines().filter_map(|line| line.split_once('=')).find(|(known, _)| *known == name).map(|(_, value)| value.to_owned());
    let config = load_config(&|name| lookup(&fresh, name)).unwrap();
    assert_eq!((config.api_key.as_str(), config.gateway_token.as_str(), config.port), (KEY, FRESH, 8_787));
    assert_eq!((config.requests_per_minute, config.tokens_per_minute, config.tokens_per_day, config.requests_per_day), (10, Some(8_000), Some(190_000), None));
    // A key rotation must not force re-pairing the phone.
    let existing = format!("# old\nGROQ_API_KEY=gsk_old\nMIO_GATEWAY_TOKEN={TOKEN}\nPORT=8787\n");
    assert!(text(gateway_env(KEY, Some(existing.as_bytes()), "qwen/qwen3.8-27b", "8787", FRESH)).contains(&format!("MIO_GATEWAY_TOKEN={TOKEN}\n")));
    for damaged in ["MIO_GATEWAY_TOKEN=short\n", "MIO_GATEWAY_TOKEN=has spaces and is long enough to count 0123456789\n", " MIO_GATEWAY_TOKEN=indented\n", ""] {
        assert!(text(gateway_env(KEY, Some(damaged.as_bytes()), "m", "1", FRESH)).contains(&format!("MIO_GATEWAY_TOKEN={FRESH}\n")), "{damaged}");
    }
}

/// Ultrareview C2: `--ny-groq-nyckel` rewrote the whole file from the template, so limits,
/// the port and task profiles the user had set were lost.
#[test]
fn a_key_rotation_changes_only_the_key_line() {
    let customised = format!("# egen kommentar\nGROQ_API_KEY=gsk_old0123456789abcdefghij\nMIO_GATEWAY_TOKEN={TOKEN}\n\
        MIO_AI_PROVIDER=groq\nMIO_AI_MODEL=qwen/qwen3.8-27b\nMIO_REQUESTS_PER_MINUTE=4\nMIO_TOKENS_PER_MINUTE=6000\n\
        MIO_TOKENS_PER_DAY=50000\nMIO_AI_TASK_PROFILES={{\"ask\":{{\"maxOutputTokens\":800}}}}\nPORT=9999\n");
    let rotated = text(gateway_env(KEY, Some(customised.as_bytes()), "qwen/qwen3.8-27b", "8787", FRESH));
    assert_eq!(rotated, customised.replace("GROQ_API_KEY=gsk_old0123456789abcdefghij", &format!("GROQ_API_KEY={KEY}")));
    // A file without a key line gets one, and a duplicate key line is not kept.
    let without = format!("MIO_GATEWAY_TOKEN={TOKEN}\nPORT=9999");
    assert_eq!(text(gateway_env(KEY, Some(without.as_bytes()), "m", "1", FRESH)), format!("MIO_GATEWAY_TOKEN={TOKEN}\nPORT=9999\nGROQ_API_KEY={KEY}\n"));
    let twice = format!("GROQ_API_KEY=a\nMIO_GATEWAY_TOKEN={TOKEN}\nGROQ_API_KEY=b\n");
    assert_eq!(text(gateway_env(KEY, Some(twice.as_bytes()), "m", "1", FRESH)), format!("GROQ_API_KEY={KEY}\nMIO_GATEWAY_TOKEN={TOKEN}\n"));
}

/// Ultrareview C3: a file saved with CRLF or with a Latin-1 byte lost its token, which forced
/// re-pairing on a key rotation and made `mio-pair` report that there is no token.
#[test]
fn windows_line_ends_and_latin1_bytes_keep_the_token() {
    let crlf = format!("# Mio\r\nGROQ_API_KEY=gsk_old\r\nMIO_GATEWAY_TOKEN={TOKEN}\r\nPORT=8787\r\n");
    assert_eq!(text(gateway_env(KEY, Some(crlf.as_bytes()), "m", "1", FRESH)),
        format!("# Mio\nGROQ_API_KEY={KEY}\nMIO_GATEWAY_TOKEN={TOKEN}\nPORT=8787\n"));
    let payload: Value = serde_json::from_str(&pairing_payload(&crlf, "dator.tailnet.ts.net").unwrap()).unwrap();
    assert_eq!(payload["aiToken"], TOKEN);
    let mut latin1 = b"# r\xe4knare\nGROQ_API_KEY=gsk_old\n".to_vec();
    latin1.extend_from_slice(format!("MIO_GATEWAY_TOKEN={TOKEN}\n").as_bytes());
    let rotated = gateway_env(KEY, Some(&latin1), "m", "1", FRESH);
    assert!(rotated.starts_with(b"# r\xe4knare\n"), "Other bytes are kept as they were");
    assert!(String::from_utf8_lossy(&rotated).contains(&format!("MIO_GATEWAY_TOKEN={TOKEN}\n")));
    let payload: Value = serde_json::from_str(&pairing_payload(&String::from_utf8_lossy(&latin1), "h").unwrap()).unwrap();
    assert_eq!(payload["aiToken"], TOKEN);
}

#[test]
fn the_pairing_code_carries_both_services_or_only_ai_and_never_a_provider_key() {
    let gateway = format!("GROQ_API_KEY={KEY}\nMIO_GATEWAY_TOKEN={TOKEN}\nPORT=8787\n");
    let transcription = "MIO_TRANSCRIPTION_TOKEN=transcription_token_0123456789012345678901\n";
    let both = pairing_payload(&format!("{gateway}{transcription}"), "dator.tailnet.ts.net").unwrap();
    assert_eq!(both, format!("{{\"mio\":1,\"aiURL\":\"https://dator.tailnet.ts.net:8443\",\"aiToken\":\"{TOKEN}\",\
        \"transcriptionURL\":\"https://dator.tailnet.ts.net\",\"transcriptionToken\":\"transcription_token_0123456789012345678901\"}}"));
    assert!(!both.contains(KEY));
    let only_ai: Value = serde_json::from_str(&pairing_payload(&gateway, "dator.tailnet.ts.net").unwrap()).unwrap();
    assert_eq!((&only_ai["transcriptionURL"], &only_ai["transcriptionToken"]), (&Value::Null, &Value::Null));
    assert_eq!(pairing_payload(transcription, "dator.tailnet.ts.net"), None);
    assert_eq!(pairing_text(&both).unwrap(), format!("AI-adress: https://dator.tailnet.ts.net:8443\nAI-token: {TOKEN}\n\
        Transkriptionsadress: https://dator.tailnet.ts.net\nTranskriptionstoken: transcription_token_0123456789012345678901\n"));
    assert_eq!(pairing_text(&only_ai.to_string()).unwrap().lines().count(), 2);
}

#[test]
fn the_tailscale_name_loses_its_trailing_dot_and_a_missing_name_is_empty() {
    assert_eq!(tailscale_host(&json!({ "Self": { "DNSName": "dator.tailnet.ts.net." } }).to_string()), "dator.tailnet.ts.net");
    for status in ["{}", "not json", r#"{"Self":{}}"#, r#"{"Self":{"DNSName":5}}"#] {
        assert_eq!(tailscale_host(status), "");
    }
}

/// Ultrareview D1: the phone refuses tokens that start like a provider key in any case, while
/// the gateway only refused `sk-`; about 1 in 32,000 generated tokens could never be paired.
#[test]
fn tokens_shaped_like_provider_keys_are_refused_and_replaced() {
    use mio_gateway::config::{is_gateway_token, looks_like_provider_key};
    for token in ["sk-", "SK_", "Gsk_", "AIza", "aIZA"] {
        let token = format!("{token}{}", "a".repeat(40));
        assert!(looks_like_provider_key(&token) && !is_gateway_token(&token), "{token}");
    }
    for token in ["skA", "gsk-", "aiz_", "Sk"] {
        let token = format!("{token}{}", "a".repeat(40));
        assert!(!looks_like_provider_key(&token) && is_gateway_token(&token), "{token}");
    }
    let shaped = format!("Sk_{}", "b".repeat(40));
    let existing = format!("GROQ_API_KEY=gsk_old\nMIO_GATEWAY_TOKEN={shaped}\nPORT=9999\n");
    assert_eq!(text(gateway_env(KEY, Some(existing.as_bytes()), "m", "1", FRESH)),
        format!("GROQ_API_KEY={KEY}\nMIO_GATEWAY_TOKEN={FRESH}\nPORT=9999\n"));
}

/// The control panel validates a file before it writes it; the answer never carries a secret.
#[test]
fn the_configuration_check_accepts_what_the_gateway_runs_and_names_no_secret() {
    let written = text(gateway_env(KEY, None, "qwen/qwen3.8-27b", "8787", FRESH));
    let answer: Value = serde_json::from_str(&check_configuration(&written).unwrap()).unwrap();
    assert_eq!(answer["valid"], json!(true));
    assert_eq!(answer["port"], json!(8_787));
    assert_eq!(answer["tasks"].as_array().unwrap().len(), 3);
    assert!(answer["tasks"].as_array().unwrap().iter().all(|task| task["model"] == "qwen/qwen3.8-27b" && task["configured"] == true));
    let printed = answer.to_string();
    assert!(!printed.contains(KEY) && !printed.contains(FRESH));
}

#[test]
fn the_configuration_check_refuses_what_the_gateway_would_refuse() {
    let written = text(gateway_env(KEY, None, "qwen/qwen3.8-27b", "8787", FRESH));
    // The gateway would not start: the message is the gateway's own and has no value in it.
    for (from, to) in [("MIO_REQUESTS_PER_MINUTE=10", "MIO_REQUESTS_PER_MINUTE=61"), ("PORT=8787", "PORT=abc"),
        (&format!("MIO_GATEWAY_TOKEN={FRESH}") as &str, "MIO_GATEWAY_TOKEN=kort")] {
        let error = check_configuration(&written.replace(from, to)).unwrap_err();
        assert!(!error.starts_with('{') && !error.contains(KEY), "{to}: {error}");
    }
    // It starts, but a task has no reviewed model or no key: the answer says which, still without secrets.
    let unreviewed = written.replace("MIO_AI_MODEL=qwen/qwen3.8-27b", "MIO_AI_MODEL=llama-3.3-70b-versatile");
    let answer: Value = serde_json::from_str(&check_configuration(&unreviewed).unwrap_err()).unwrap();
    assert_eq!(answer["valid"], json!(false));
    assert_eq!(answer["tasks"][0]["error"], json!("provider_model_incompatible"));
    let keyless = written.replace(&format!("GROQ_API_KEY={KEY}"), "GROQ_API_KEY=");
    let answer: Value = serde_json::from_str(&check_configuration(&keyless).unwrap_err()).unwrap();
    assert_eq!(answer["tasks"][1]["error"], json!("provider_secret_missing"));
    let per_task = written.replace("PORT=8787", "PORT=8787\nMIO_AI_TASK_PROFILES={\"lesson\":{\"model\":\"other/model\"}}");
    let answer: Value = serde_json::from_str(&check_configuration(&per_task).unwrap_err()).unwrap();
    assert_eq!((answer["tasks"][0]["configured"].clone(), answer["tasks"][2]["model"].clone()), (json!(true), json!("other/model")));
}

#[test]
fn environment_files_are_read_like_systemd_reads_them() {
    let variables = environment_file("# kommentar\n; också\n\nA=1\r\n B = två \nC=\"citerad\"\nD='enkel'\nE=\"\nA=sist\nutan likhetstecken\n");
    let pairs: Vec<(&str, &str)> = variables.iter().map(|(key, value)| (key.as_str(), value.as_str())).collect();
    assert_eq!(pairs, [("A", "sist"), ("B", "två"), ("C", "citerad"), ("D", "enkel"), ("E", "\"")]);
}

#[test]
fn the_reviewed_models_list_the_pairs_the_gateway_accepts() {
    let listed: Value = serde_json::from_str(&reviewed_models()).unwrap();
    assert_eq!(listed["providers"], json!(["groq", "anthropic", "mistral", "nvidia", "openai", "openrouter", "gemini"]));
    let pairs: Vec<(Value, Value, Value, Value)> = listed["models"].as_array().unwrap().iter()
        .map(|model| (model["provider"].clone(), model["model"].clone(), model["secretVariable"].clone(), model["temperature"].clone())).collect();
    assert_eq!(pairs, [
        (json!("groq"), json!("qwen/qwen3.8-27b"), json!("GROQ_API_KEY"), json!("0")),
        (json!("anthropic"), json!("claude-haiku-5-5"), json!("ANTHROPIC_API_KEY"), json!("provider-default")),
    ]);
    assert!(listed["models"].as_array().unwrap().iter().all(|model| model["liveTested"] == false && model["blocked"].is_null()));
    // Candidates are listed with why they cannot be chosen; the gateway refuses them.
    let candidates = listed["candidates"].as_array().unwrap();
    assert_eq!(candidates.len(), 14);
    assert!(candidates.iter().all(|candidate| candidate["blocked"].as_str().is_some_and(|reason| reason.contains("prov"))));
}
