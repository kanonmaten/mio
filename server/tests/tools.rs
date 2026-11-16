use mio_gateway::config::load_config;
use mio_gateway::tools::{gateway_env, pairing_payload, pairing_text, tailscale_host};
use serde_json::{Value, json};

const TOKEN: &str = "fixture_gateway_token_01234567890123456789";
const FRESH: &str = "fresh_gateway_token_0123456789012345678901";
const KEY: &str = "gsk_fixture0123456789abcdefghij";

#[test]
fn the_written_configuration_loads_and_keeps_an_existing_gateway_token() {
    let fresh = gateway_env(KEY, None, "qwen/qwen3.8-27b", "8787", FRESH);
    assert!(fresh.starts_with("# Mio gateway.") && fresh.ends_with("PORT=8787\n"));
    assert!(fresh.contains(&format!("GROQ_API_KEY={KEY}\nMIO_GATEWAY_TOKEN={FRESH}\n")));
    // What install.sh writes is what the gateway reads: systemd passes each NAME=value line on.
    let lookup = |text: &str, name: &str| text.lines().filter_map(|line| line.split_once('=')).find(|(known, _)| *known == name).map(|(_, value)| value.to_owned());
    let config = load_config(&|name| lookup(&fresh, name)).unwrap();
    assert_eq!((config.api_key.as_str(), config.gateway_token.as_str(), config.port), (KEY, FRESH, 8_787));
    assert_eq!((config.requests_per_minute, config.tokens_per_minute, config.tokens_per_day, config.requests_per_day), (10, Some(8_000), Some(190_000), None));
    // A key rotation must not force re-pairing the phone.
    let existing = format!("# old\nGROQ_API_KEY=gsk_old\nMIO_GATEWAY_TOKEN={TOKEN}\nPORT=8787\n");
    assert!(gateway_env(KEY, Some(&existing), "qwen/qwen3.8-27b", "8787", FRESH).contains(&format!("MIO_GATEWAY_TOKEN={TOKEN}\n")));
    for damaged in ["MIO_GATEWAY_TOKEN=short\n", "MIO_GATEWAY_TOKEN=has spaces and is long enough to count 0123456789\n", " MIO_GATEWAY_TOKEN=indented\n", ""] {
        assert!(gateway_env(KEY, Some(damaged), "m", "1", FRESH).contains(&format!("MIO_GATEWAY_TOKEN={FRESH}\n")), "{damaged}");
    }
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
