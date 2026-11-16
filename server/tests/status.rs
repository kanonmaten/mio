mod common;

use std::sync::Arc;

use common::{CountingStore, Link, MODEL, Provider, TOKEN, Upstream, authorized, env, start};
use mio_gateway::config::{Config, ConfigError, load_config};
use mio_gateway::server::Gateway;
use mio_gateway::status::*;
use serde_json::{Value, json};

fn base() -> Config {
    Config { model: MODEL.to_owned(), api_key: "fixture-upstream".to_owned(), gateway_token: TOKEN.to_owned(), requests_per_minute: 6,
        requests_per_day: Some(100), upstream_timeout_ms: 1_000, body_timeout_ms: 1_000,
        provider_secrets: [("groq".to_owned(), "fixture-upstream".to_owned())].into(), ..Config::default() }
}

fn with_profiles(profiles: Value) -> Config {
    Config { task_profiles: Some(profiles), ..base() }
}

fn header<'a>(headers: &'a [(&'static str, String)], name: &str) -> Option<&'a str> {
    headers.iter().find(|(known, _)| *known == name).map(|(_, value)| value.as_str())
}

#[test]
fn status_exposes_safe_configuration_metadata_despite_invalid_provider_key_or_limits() {
    let base = [("MIO_AI_PROVIDER", "groq"), ("MIO_AI_MODEL", MODEL), ("GROQ_API_KEY", "fixture-key"), ("MIO_GATEWAY_TOKEN", TOKEN)];
    let status = |extra: &[(&str, &str)]| {
        let values = env(&[&base[..], extra].concat());
        status_from_environment(&values, &load_config(&values))
    };
    assert_eq!(status(&[])["configured"], true);
    for patch in [("GROQ_API_KEY", ""), ("MIO_AI_MODEL", "unreviewed-model"), ("MIO_REQUESTS_PER_DAY", "-1"),
        ("MIO_LESSON_INTERVAL_SECONDS", "59"), ("GROQ_API_KEY", TOKEN)] {
        assert_eq!(status(&[patch])["configured"], false, "{patch:?}");
    }
    let invalid = status(&[("MIO_AI_PROVIDER", "private secret\n"), ("MIO_AI_MODEL", "secret\r\nCookie: password")]);
    assert_eq!((&invalid["provider"], &invalid["model"], &invalid["configured"]), (&json!(""), &json!(""), &json!(false)));
    let bearer = format!("Bearer {TOKEN}");
    assert!(authenticated(Some(&bearer), TOKEN));
    assert!(!authenticated(Some(&bearer), ""));
    assert!(!authenticated(Some("Bearer wrong"), TOKEN));
    assert!(!authenticated(None, TOKEN));
}

#[test]
fn v2_status_reports_individual_task_contracts_and_safe_fixed_configuration_failures() {
    let status = gateway_status_v2(&with_profiles(json!({ "lesson": { "model": "unreviewed-model" } })), None);
    let revision = status["configurationRevision"].as_str().unwrap();
    assert_eq!(status["protocolVersion"], 2);
    assert!(is_revision(revision));
    assert_eq!(status["tasks"].as_object().unwrap().keys().collect::<Vec<_>>(), ["ask", "everyday", "lesson"]);
    for (task, contract) in [("ask", "ask-v1"), ("everyday", "analysis-context-v2"), ("lesson", "lesson-notes-v1")] {
        let item = &status["tasks"][task];
        assert_eq!(item["configured"], task != "lesson");
        assert_eq!(item["provider"], "groq");
        let capabilities = item["capabilities"].as_array().unwrap();
        for required in ["reasoning-off", "temperature-zero", "strict-json", contract] {
            assert!(capabilities.contains(&json!(required)));
        }
        assert_eq!(item["configurationError"], if task == "lesson" { json!("provider_model_incompatible") } else { Value::Null });
        assert_eq!(capabilities.contains(&json!("analysis-backlog-v1")), task == "everyday");
    }
    assert_eq!(status["quota"], json!({ "limit": 100, "remaining": null, "resetAt": null, "unit": "requests" }));
    assert_eq!(header(&metadata_headers("groq", MODEL, "2026-10-13.2", Some(revision)), "X-Mio-Configuration-Revision"), Some(revision));
    let serialized = status.to_string();
    for private in ["fixture-upstream", TOKEN, "providerSecrets", "apiKey"] {
        assert!(!serialized.contains(private));
    }
}

#[test]
fn revision_is_canonical_changes_with_effective_task_configuration_and_limits_and_excludes_credentials() {
    let profiles = json!({ "ask": { "model": MODEL }, "lesson": { "model": "unreviewed-model" } });
    let revision = configuration_revision(&with_profiles(profiles.clone()));
    assert_eq!(revision, configuration_revision(&with_profiles(json!({ "lesson": { "model": "unreviewed-model" }, "ask": { "model": MODEL } }))));
    assert_eq!(revision, configuration_revision(&Config { api_key: "rotated-fixture".to_owned(),
        gateway_token: "rotated_gateway_token_01234567890123456789".to_owned(),
        provider_secrets: [("groq".to_owned(), "rotated-groq".to_owned())].into(), ..with_profiles(json!(profiles.to_string())) }));
    assert_ne!(revision, configuration_revision(&with_profiles(json!({ "ask": { "model": MODEL }, "lesson": { "model": MODEL } }))));
    assert_ne!(revision, configuration_revision(&Config { requests_per_day: Some(99), ..with_profiles(profiles.clone()) }));
    assert_ne!(revision, configuration_revision(&Config { tokens_per_day: Some(190_000), ..with_profiles(profiles) }));
}

#[test]
fn a_token_cap_is_reported_with_its_unit_and_takes_precedence_over_a_request_cap() {
    let quota = QuotaObservation { remaining: Some(1_000), reset_at: Some("2026-10-12T00:00:00.000Z".to_owned()) };
    let status = gateway_status_v2(&Config { tokens_per_day: Some(190_000), ..base() }, Some(&quota));
    assert_eq!(status["quota"], json!({ "limit": 190000, "remaining": 1000, "resetAt": "2026-10-12T00:00:00.000Z", "unit": "tokens" }));
    assert_eq!(gateway_status_v2(&Config { requests_per_day: None, ..base() }, None)["quota"], Value::Null);
}

#[test]
fn unsafe_public_identifiers_and_arbitrary_quota_values_are_never_reflected_in_status() {
    let config = Config { provider: "private\nheader".to_owned(), model: "https://private.fixture.invalid/model".to_owned(), ..base() };
    let quota = QuotaObservation { remaining: Some(-1), reset_at: Some("private arbitrary body".to_owned()) };
    let status = gateway_status_v2(&config, Some(&quota));
    assert_eq!((&status["tasks"]["ask"]["provider"], &status["tasks"]["ask"]["model"]), (&json!(""), &json!("")));
    assert_eq!(status["quota"], json!({ "limit": 100, "remaining": null, "resetAt": null, "unit": "requests" }));
    for reset_at in ["2026-99-01T00:00:00.000Z", "2026-02-30T00:00:00.000Z"] {
        let quota = QuotaObservation { remaining: Some(99), reset_at: Some(reset_at.to_owned()) };
        assert_eq!(gateway_status_v2(&base(), Some(&quota))["quota"]["resetAt"], Value::Null);
    }
}

#[test]
fn credential_shaped_configured_identifiers_never_enter_public_discovery_or_metadata_headers() {
    for prefix in ["sk-", "SK-", "sk_", "Sk_", "gsk_", "GSK_", "AIza", "aIzA"] {
        let private = format!("{prefix}fixture-private");
        let model = gateway_status_v2(&with_profiles(json!({ "lesson": { "model": private } })), None);
        let provider = gateway_status_v2(&with_profiles(json!({ "lesson": { "provider": private } })), None);
        assert_eq!((&model["tasks"]["lesson"]["model"], &provider["tasks"]["lesson"]["provider"]), (&json!(""), &json!("")));
        assert_eq!((&model["tasks"]["ask"]["configured"], &provider["tasks"]["ask"]["configured"]), (&json!(true), &json!(true)));
        assert!(!model.to_string().contains(&private) && !provider.to_string().contains(&private));
        let headers = metadata_headers(&private, &private, "", None);
        assert_eq!((header(&headers, "X-Mio-Provider"), header(&headers, "X-Mio-Model")), (Some(""), Some("")));
    }
}

#[test]
fn environment_discovery_distinguishes_global_configuration_failures_without_exposing_private_parse_errors() {
    let profiles = json!({ "ask": { "provider": "groq", "model": MODEL } }).to_string();
    let values = env(&[("MIO_AI_PROVIDER", "groq"), ("MIO_AI_MODEL", MODEL), ("MIO_REQUESTS_PER_DAY", "0"), ("MIO_AI_TASK_PROFILES", &profiles)]);
    let quota = QuotaObservation { remaining: Some(5), reset_at: Some("2026-10-03T00:00:00.000Z".to_owned()) };
    let status = status_v2_from_environment(&values, &Err(ConfigError("private credential or configuration text")), Some(&quota));
    for task in status["tasks"].as_object().unwrap().values() {
        assert_eq!((&task["configured"], &task["configurationError"]), (&json!(false), &json!("gateway_configuration_invalid")));
    }
    assert_eq!((&status["tasks"]["ask"]["provider"], &status["tasks"]["ask"]["model"]), (&json!("groq"), &json!(MODEL)));
    assert_eq!(status["quota"], Value::Null);
    assert!(!status.to_string().contains("private credential"));
}

#[tokio::test]
async fn protected_v2_status_makes_no_provider_call_or_quota_reservation_and_exposes_revision_metadata() {
    let provider = Provider::fixed(Upstream::Fail);
    let store = Arc::new(CountingStore::default());
    let server = start(Gateway::new(base(), Arc::new(Link(provider.clone()))).unwrap().with_store(store.clone())).await;
    assert_eq!(server.get("/v2/status", &[]).await.status, 401);
    let response = server.get("/v2/status", &authorized()).await;
    assert_eq!(response.status, 200);
    let status = response.json();
    assert_eq!(response.header("x-mio-configuration-revision"), status["configurationRevision"].as_str());
    assert_eq!(status["tasks"].as_object().unwrap().keys().collect::<Vec<_>>(), ["ask", "everyday", "lesson"]);
    assert_eq!((provider.count(), store.saves.load(std::sync::atomic::Ordering::SeqCst)), (0, 0));
}

#[test]
fn v1_status_describes_the_effective_everyday_task_profile_for_older_clients() {
    let base = Config { api_key: "fixture-key".to_owned(), gateway_token: TOKEN.to_owned(), model: MODEL.to_owned(), ..Config::default() };
    assert_eq!(gateway_status(&base)["configured"], true);
    let broken = gateway_status(&Config { task_profiles: Some(json!({ "everyday": { "model": "not-a-reviewed-model" } })), ..base });
    assert_eq!(broken["configured"], false, "v1 must not report an everyday task that /v1/analyze refuses");
    assert_eq!(broken["model"], "not-a-reviewed-model");
}
