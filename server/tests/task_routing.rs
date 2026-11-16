mod common;

use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use common::{Call, CountingStore, Link, MODEL, Provider, Server, TOKEN, Upstream, authorized, env, start};
use mio_gateway::config::{Config, load_config};
use mio_gateway::server::Gateway;
use serde_json::{Value, json};

const BASE: [(&str, &str); 5] = [("MIO_AI_MODEL", MODEL), ("GROQ_API_KEY", "fixture-groq"), ("MIO_GATEWAY_TOKEN", TOKEN),
    ("MIO_REQUESTS_PER_MINUTE", "60"), ("MIO_REQUESTS_PER_DAY", "100")];

fn load(patch: &[(&str, &str)]) -> Config {
    load_config(&env(&[&BASE[..], patch].concat())).unwrap()
}

fn approved() -> Value {
    json!({ "question": "Syntetiskt godkänt prov", "context": [] })
}

/// Echoes the requested model, as the provider does.
fn completion(_: usize, call: &Call) -> Upstream {
    let request: Value = serde_json::from_str(&call.body).unwrap();
    Upstream::new(200, &[("Content-Type", "application/json"), ("x-request-id", "fixture-upstream-request")], json!({
        "model": request["model"], "choices": [{ "finish_reason": "stop", "message": { "role": "assistant", "content": "{\"answer\":\"Syntetiskt svar\"}" } }],
        "usage": { "prompt_tokens": 7, "completion_tokens": 3, "completion_tokens_details": { "reasoning_tokens": 0 } } }).to_string())
}

struct Fixture {
    server: Server,
    provider: Arc<Provider>,
    store: Arc<CountingStore>,
}

impl Fixture {
    async fn ask(&self, extra: &[(&'static str, &str)]) -> common::Reply {
        self.server.post_with("/v1/ask", &approved(), extra).await
    }

    /// Every reservation persists the counters before provider traffic; counting saves observes it.
    fn reservations(&self) -> usize {
        self.store.saves.load(Ordering::SeqCst)
    }
}

async fn fixture_with(patch: &[(&str, &str)], provider: Arc<Provider>, store: CountingStore, build: impl FnOnce(Gateway) -> Gateway) -> Fixture {
    let store = Arc::new(store);
    let gateway = build(Gateway::new(load(patch), Arc::new(Link(provider.clone()))).unwrap().with_store(store.clone()));
    Fixture { server: start(gateway).await, provider, store }
}

async fn fixture(patch: &[(&str, &str)]) -> Fixture {
    fixture_with(patch, Provider::new(completion), CountingStore::default(), |gateway| gateway).await
}

#[tokio::test]
async fn ask_uses_the_groq_secret_and_exact_approved_input_without_fallback() {
    let f = fixture(&[]).await;
    let response = f.ask(&[]).await;
    assert_eq!(response.status, 200);
    assert_eq!(response.json(), json!({ "answer": "Syntetiskt svar" }));
    assert_eq!(f.provider.count(), 1);
    {
        let calls = f.provider.calls.lock().unwrap();
        assert_eq!(calls[0].url, "https://api.groq.com/openai/v1/chat/completions");
        assert_eq!(calls[0].authorization, "Bearer fixture-groq");
    }
    let body = f.provider.body(0);
    assert_eq!(body["model"], MODEL);
    assert_eq!(serde_json::from_str::<Value>(body["messages"][1]["content"].as_str().unwrap()).unwrap(), approved());
    assert_eq!(response.header("x-mio-provider"), Some("groq"));
    assert_eq!(response.header("x-mio-returned-model"), Some(MODEL));
    assert_eq!(response.header("x-mio-usage-input-tokens"), Some("7"));
    assert_eq!(response.header("x-mio-upstream-request-id"), Some("fixture-upstream-request"));
}

#[tokio::test]
async fn invalid_selected_task_is_rejected_before_quota_and_provider_traffic() {
    let profiles = json!({ "ask": { "provider": "openai", "model": "gpt-4.1" } }).to_string();
    let f = fixture(&[("MIO_AI_TASK_PROFILES", &profiles)]).await;
    let response = f.ask(&[]).await;
    assert_eq!((response.status, response.error().as_str()), (422, "task_configuration_invalid"));
    assert_eq!((f.reservations(), f.provider.count()), (0, 0));
}

#[tokio::test]
async fn protected_model_free_status_and_stale_revision_never_reserve_quota_or_start_inference() {
    let f = fixture(&[]).await;
    assert_eq!(f.server.get("/v2/status", &[]).await.status, 401);
    let status = f.server.status_v2().await;
    assert!(mio_gateway::status::is_revision(status["configurationRevision"].as_str().unwrap()));
    assert_eq!((&status["quota"]["limit"], &status["quota"]["remaining"], &status["tasks"]["ask"]["configured"]), (&json!(100), &json!(100), &json!(true)));
    let changed = f.ask(&[("X-Mio-Configuration-Revision", &"0".repeat(64))]).await;
    assert_eq!((changed.status, changed.error().as_str()), (409, "configuration_changed"));
    assert_eq!((f.reservations(), f.provider.count()), (0, 0));
}

#[tokio::test]
async fn budget_store_failure_is_distinct_and_cannot_trigger_provider_traffic() {
    let f = fixture_with(&[], Provider::new(completion), CountingStore::failing(), |gateway| gateway).await;
    let response = f.ask(&[]).await;
    assert_eq!(response.status, 503);
    assert_eq!(response.json(), json!({ "error": "budget_store_failed" }));
    assert_eq!(f.provider.count(), 0);
}

#[tokio::test]
async fn provider_http_statuses_return_bounded_categories() {
    for (status, category) in [(401, "provider_authentication"), (402, "provider_account"), (404, "provider_model_unavailable"),
        (400, "provider_parameters"), (429, "provider_quota"), (500, "provider_infrastructure")] {
        let provider = Provider::fixed(Upstream::new(status, &[("Content-Type", "application/json")], json!({ "error": { "message": "private arbitrary body" } }).to_string()));
        let f = fixture_with(&[], provider, CountingStore::default(), |gateway| gateway).await;
        assert_eq!(f.ask(&[]).await.error(), category, "{status}");
    }
}

#[tokio::test]
async fn local_daily_capacity_is_observed_without_changing_reservations_or_counters() {
    let f = fixture(&[]).await;
    assert_eq!(f.server.status_v2().await["quota"]["remaining"], 100);
    assert_eq!(f.ask(&[]).await.status, 200);
    assert_eq!(f.server.status_v2().await["quota"]["remaining"], 99);
    assert_eq!(f.server.status_v2().await["quota"]["remaining"], 99);
    assert_eq!(f.provider.count(), 1);
}

#[tokio::test]
async fn request_snapshots_use_current_task_configuration_and_credential_rotations_independently() {
    let current = Arc::new(Mutex::new(load(&[])));
    let source = current.clone();
    let f = fixture_with(&[], Provider::new(completion), CountingStore::default(),
        |gateway| gateway.with_configuration_source(move || source.lock().unwrap().clone())).await;
    let revision = |status: Value| status["configurationRevision"].as_str().unwrap().to_owned();
    let first = revision(f.server.status_v2().await);
    *current.lock().unwrap() = load(&[("GROQ_API_KEY", "fixture-rotated-groq")]);
    assert_eq!(revision(f.server.status_v2().await), first, "Secrets must not enter revision fingerprints");
    assert_eq!(f.ask(&[("X-Mio-Configuration-Revision", &first)]).await.status, 200);
    assert_eq!(f.provider.calls.lock().unwrap().last().unwrap().authorization, "Bearer fixture-rotated-groq");
    *current.lock().unwrap() = load(&[("MIO_TOKENS_PER_DAY", "190000")]);
    let changed = revision(f.server.status_v2().await);
    assert_ne!(changed, first);
    assert_eq!(f.ask(&[("X-Mio-Configuration-Revision", &first)]).await.status, 409);
    assert_eq!(f.provider.count(), 1);
    assert_eq!(f.ask(&[("X-Mio-Configuration-Revision", &changed)]).await.status, 200);
    assert_eq!(f.provider.body(1)["model"], MODEL);
}

#[tokio::test]
async fn minute_and_day_denials_remain_distinguishable() {
    for (variable, expected) in [("MIO_REQUESTS_PER_MINUTE", "local_minute_limit"), ("MIO_REQUESTS_PER_DAY", "local_day_limit")] {
        let f = fixture(&[(variable, "1")]).await;
        assert_eq!(f.ask(&[]).await.status, 200);
        let exhausted = f.ask(&[]).await;
        assert_eq!((exhausted.status, exhausted.error().as_str()), (429, expected));
        assert_eq!(f.provider.count(), 1);
    }
}

#[tokio::test]
async fn without_a_daily_cap_status_reports_no_quota_and_requests_are_limited_only_per_minute() {
    let f = fixture(&[("MIO_REQUESTS_PER_DAY", ""), ("MIO_REQUESTS_PER_MINUTE", "2")]).await;
    assert_eq!(f.server.status_v2().await["quota"], Value::Null);
    assert_eq!((f.ask(&[]).await.status, f.ask(&[]).await.status), (200, 200));
    let limited = f.ask(&[]).await;
    assert_eq!((limited.status, limited.error().as_str()), (429, "local_minute_limit"));
    assert_eq!(f.provider.count(), 2);
}

#[tokio::test]
async fn malformed_revisions_never_start_provider_work_or_reserve_quota() {
    let f = fixture(&[]).await;
    let status = f.server.status_v2().await;
    assert_eq!((&status["quota"]["remaining"], &status["quota"]["unit"]), (&json!(100), &json!("requests")));
    let response = f.ask(&[("X-Mio-Configuration-Revision", "secret\tvalue")]).await;
    assert_eq!((response.status, response.error().as_str()), (400, "invalid_configuration_revision"));
    // Two revision headers are as malformed as one bad one.
    let revision = status["configurationRevision"].as_str().unwrap().to_owned();
    let mut headers = authorized();
    headers.extend([("X-Mio-Configuration-Revision", revision.clone()), ("X-Mio-Configuration-Revision", revision)]);
    let doubled = f.server.request("POST", "/v1/ask", &headers, Some(approved().to_string().as_bytes())).await;
    assert_eq!((doubled.status, doubled.error().as_str()), (400, "invalid_configuration_revision"));
    assert_eq!((f.provider.count(), f.reservations()), (0, 0));
}
