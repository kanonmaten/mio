mod common;

use std::os::unix::fs::PermissionsExt;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

use common::{CountingStore, Link, MODEL, Provider, Server, TOKEN, Upstream, config, env, serve, start, with};
use mio_gateway::analysis::validate_ask_payload;
use mio_gateway::config::{Config, load_config};
use mio_gateway::server::Gateway;
use mio_gateway::state_store::{CounterStore, Counters, FileCounterStore};
use mio_gateway::task_profiles::resolve_task_profile;
use serde_json::{Value, json};

fn payload() -> Value {
    json!({ "question": "Vad betyder procent?", "context": [{ "label": "Anteckning", "text": "Vi övar procent." }] })
}

fn answer(text: &str) -> Upstream {
    Upstream::completion(&json!({ "answer": text }))
}

fn default_provider() -> Arc<Provider> {
    Provider::fixed(answer("Procent betyder hundradelar."))
}

fn usage_completion(total: u64) -> Upstream {
    Upstream::json(&json!({ "usage": { "prompt_tokens": total - 10, "completion_tokens": 10, "total_tokens": total },
        "choices": [{ "finish_reason": "stop", "message": { "role": "assistant", "content": "{\"answer\":\"Svar.\"}" } }] }))
}

struct Clock(Arc<AtomicI64>);

impl Clock {
    fn at(time: i64) -> Self {
        Self(Arc::new(AtomicI64::new(time)))
    }

    fn set(&self, time: i64) {
        self.0.store(time, Ordering::SeqCst);
    }

    async fn serve(&self, config: Config, provider: &Arc<Provider>) -> Server {
        let time = self.0.clone();
        start(Gateway::new(config, Arc::new(Link(provider.clone()))).unwrap().with_clock(move || time.load(Ordering::SeqCst))).await
    }
}

const NOON: i64 = 1_791_720_000_000; // 2026-10-11T12:00:00Z
const ENV: [(&str, &str); 3] = [("GROQ_API_KEY", "fixture"), ("MIO_GATEWAY_TOKEN", TOKEN), ("MIO_AI_MODEL", MODEL)];

fn load(patch: &[(&str, &str)]) -> Result<Config, mio_gateway::config::ConfigError> {
    load_config(&env(&[&ENV[..], patch].concat()))
}

#[test]
fn transport_settings_stay_bounded_while_invalid_generation_configuration_remains_discoverable() {
    assert!(load_config(&env(&[])).is_err());
    let unreviewed = load_config(&env(&[("GROQ_API_KEY", TOKEN), ("MIO_GATEWAY_TOKEN", TOKEN), ("MIO_AI_MODEL", "example")])).unwrap();
    assert!(!resolve_task_profile(&unreviewed, "ask").configured);
    assert!(load(&[("MIO_AI_MODEL", "example"), ("MIO_REQUESTS_PER_DAY", "1000001")]).is_err());
    assert_eq!(load(&[("MIO_AI_MODEL", "example")]).unwrap().requests_per_day, None);
    // Groq free tier: requests are sized against 8,000 tokens per minute; the daily cap is optional.
    let defaults = load(&[]).unwrap();
    assert_eq!((defaults.provider.as_str(), defaults.requests_per_minute, defaults.tokens_per_minute, defaults.tokens_per_day),
        ("groq", 10, Some(8_000), None));
    for off in ["", "0"] {
        assert_eq!(load(&[("MIO_TOKENS_PER_MINUTE", off)]).unwrap().tokens_per_minute, None);
    }
    assert!(load(&[("MIO_TOKENS_PER_MINUTE", "500")]).is_err());
    // A token budget is bounded by the token maximum, not the request one (ultrareview C5).
    let most = mio_gateway::config::MAX_TOKENS_PER_DAY.to_string();
    assert_eq!(load(&[("MIO_TOKENS_PER_MINUTE", &most)]).unwrap().tokens_per_minute, Some(mio_gateway::config::MAX_TOKENS_PER_DAY));
    assert!(load(&[("MIO_TOKENS_PER_MINUTE", &(mio_gateway::config::MAX_TOKENS_PER_DAY + 1).to_string())]).is_err());
}

#[test]
fn payload_preserves_exactly_approved_text_and_refuses_unknown_fields() {
    assert!(validate_ask_payload(&payload()).is_ok());
    let context = payload()["context"][0].clone();
    for invalid in [with(&payload(), json!({ "history": [] })), json!({ "question": " ", "context": [] }),
        json!({ "question": "å".repeat(1001), "context": [] }), json!({ "question": "Hej", "context": vec![context; 7] }),
        json!({ "question": "Hej", "context": [{ "label": "a", "text": "" }] }),
        json!({ "question": "Hej", "context": [{ "label": "a", "text": "x".repeat(4001) }] }),
        json!({ "question": "Hej", "context": vec![json!({ "label": "a", "text": "x".repeat(3500) }); 3] })] {
        assert!(validate_ask_payload(&invalid).is_err());
    }
}

#[tokio::test]
async fn health_and_unknown_routes_never_contact_the_provider() {
    let provider = default_provider();
    let server = serve(config(), &provider).await;
    let health = server.get("/health", &[]).await;
    assert_eq!(health.json(), json!({ "status": "ok" }));
    // One request per connection: the reply says so and the socket closes.
    assert_eq!(health.header("connection"), Some("close"));
    assert_eq!(server.get("/unknown", &[]).await.status, 404);
    assert_eq!(server.get("/health?probe=1", &[]).await.status, 404);
    assert_eq!(provider.count(), 0);
}

#[tokio::test]
async fn unauthorized_requests_cannot_spend_api_credits_or_leak_credentials() {
    let provider = default_provider();
    let server = serve(config(), &provider).await;
    for authorization in ["", "Bearer wrong", &format!("Bearer {TOKEN}extra")] {
        let response = server.post_with("/v1/ask", &payload(), &[("Authorization", authorization)]).await;
        assert_eq!(response.status, 401);
        assert_eq!(response.json(), json!({ "error": "unauthorized" }));
    }
    assert_eq!(provider.count(), 0);
}

#[tokio::test]
async fn success_uses_fixed_upstream_no_storage_no_tools_and_only_approved_context() {
    let provider = default_provider();
    let server = serve(config(), &provider).await;
    let response = server.post("/v1/ask", &payload()).await;
    assert_eq!(response.status, 200);
    assert_eq!(response.header("cache-control"), Some("no-store"));
    assert_eq!(response.header("x-content-type-options"), Some("nosniff"));
    assert_eq!(response.json(), json!({ "answer": "Procent betyder hundradelar." }));
    assert_eq!(provider.count(), 1);
    {
        let calls = provider.calls.lock().unwrap();
        assert_eq!(calls[0].url, "https://api.groq.com/openai/v1/chat/completions");
        assert_eq!(calls[0].authorization, "Bearer fixture-upstream-credential");
        assert!(!calls[0].body.contains(TOKEN));
    }
    let request = provider.body(0);
    assert_eq!((&request["max_tokens"], &request["stream"]), (&json!(1200), &json!(false)));
    assert!(request.get("tools").is_none() && request.get("previous_response_id").is_none());
    assert_eq!(request["messages"].as_array().unwrap().len(), 2);
    assert_eq!(serde_json::from_str::<Value>(request["messages"][1]["content"].as_str().unwrap()).unwrap(), payload());
}

#[tokio::test]
async fn invalid_json_content_types_and_too_large_bodies_are_rejected_locally() {
    let provider = default_provider();
    let server = serve(config(), &provider).await;
    let raw = |body: String| { let server = &server; async move { server.request("POST", "/v1/ask", &common::authorized(), Some(body.as_bytes())).await.status } };
    assert_eq!(raw("{broken".to_owned()).await, 400);
    assert_eq!(server.post_with("/v1/ask", &payload(), &[("Content-Type", "text/plain")]).await.status, 415);
    assert_eq!(server.post_with("/v1/ask", &payload(), &[("Content-Encoding", "gzip")]).await.status, 415);
    assert_eq!(raw("x".repeat(40_001)).await, 413);
    assert_eq!(provider.count(), 0);
}

#[tokio::test]
async fn a_body_sent_without_a_declared_length_is_bounded_while_it_arrives() {
    use tokio::io::AsyncWriteExt;
    let provider = default_provider();
    let server = serve(config(), &provider).await;
    let mut stream = server.connect().await;
    let head = format!("POST /v1/ask HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {TOKEN}\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n");
    stream.write_all(head.as_bytes()).await.unwrap();
    for _ in 0..6 {
        let _ = stream.write_all(format!("2000\r\n{}\r\n", "x".repeat(8_192)).as_bytes()).await;
    }
    let response = common::read_reply(&mut stream).await;
    assert_eq!((response.status, response.error().as_str()), (413, "request_too_large"));
    assert_eq!(provider.count(), 0);
}

#[tokio::test]
async fn upstream_errors_expose_only_fixed_error_codes_and_are_retried_exactly_once() {
    let provider = Provider::fixed(Upstream::new(500, &[], "private upstream details"));
    let response = serve(Config { retry_delay_ms: Some(1), ..config() }, &provider).await.post("/v1/ask", &payload()).await;
    assert_eq!(response.status, 502);
    assert_eq!(response.json(), json!({ "error": "provider_infrastructure" }));
    assert_eq!(provider.count(), 2);
}

#[tokio::test]
async fn one_retry_recovers_a_brief_provider_failure_and_a_short_provider_wait_with_the_identical_request() {
    for failure in [Upstream::new(503, &[], "down"),
        Upstream::new(429, &[("Content-Type", "application/json"), ("Retry-After", "0.01")], r#"{"error":{"code":"rate_limit_exceeded"}}"#),
        Upstream::Fail] {
        let provider = Provider::new(move |index, _| if index == 0 { failure.clone() } else { answer("Svar.") });
        let server = serve(Config { retry_delay_ms: Some(1), upstream_timeout_ms: 5_000, ..config() }, &provider).await;
        assert_eq!(server.post("/v1/ask", &payload()).await.status, 200);
        {
            let calls = provider.calls.lock().unwrap();
            assert_eq!(calls.len(), 2);
            assert_eq!(calls[0].body, calls[1].body);
        }
        // The retry is the same reserved request: the local counter moved once.
        assert_eq!(server.status_v2().await["quota"]["remaining"], 99);
    }
}

#[tokio::test]
async fn a_long_provider_wait_a_size_refusal_and_an_invalid_answer_are_never_retried() {
    let json_type = ("Content-Type", "application/json");
    for (upstream, status, code, retry_after) in [
        (Upstream::new(429, &[json_type, ("Retry-After", "45")], "{}"), 429, "provider_quota", Some("45")),
        (Upstream::new(429, &[json_type], "{}"), 429, "provider_quota", Some("60")),
        // Groq: one request larger than the per-minute token budget. Waiting cannot help.
        (Upstream::new(413, &[json_type, ("Retry-After", "2")], r#"{"error":{"type":"tokens","code":"rate_limit_exceeded"}}"#), 413, "provider_request_too_large", None),
        (Upstream::new(401, &[json_type], "{}"), 502, "provider_authentication", None)] {
        let provider = Provider::fixed(upstream);
        let response = serve(Config { retry_delay_ms: Some(1), upstream_timeout_ms: 5_000, ..config() }, &provider).await.post("/v1/ask", &payload()).await;
        assert_eq!((response.status, response.error().as_str(), response.header("retry-after")), (status, code, retry_after));
        assert_eq!(provider.count(), 1);
    }
}

#[tokio::test]
async fn requests_are_sized_to_the_per_minute_token_budget_before_any_quota_or_provider_call() {
    let provider = default_provider();
    let server = serve(Config { tokens_per_minute: Some(2_000), ..config() }, &provider).await;
    let ask = |text: String| json!({ "question": "Hej", "context": if text.is_empty() { json!([]) } else { json!([{ "label": "a", "text": text }]) } });
    // A short question keeps its full answer reservation.
    assert_eq!(server.post("/v1/ask", &ask(String::new())).await.status, 200);
    assert_eq!(provider.body(0)["max_tokens"], 1200);
    // A larger prompt shrinks the reservation so prompt + max_tokens still fit the minute.
    assert_eq!(server.post("/v1/ask", &ask("x".repeat(1_500))).await.status, 200);
    let shrunk = provider.body(1)["max_tokens"].as_u64().unwrap();
    assert!((300..1200).contains(&shrunk), "{shrunk}");
    // A prompt that leaves no room for an answer is refused locally: no provider call, no quota.
    let refused = server.post("/v1/ask", &ask("x".repeat(4_000))).await;
    assert_eq!((refused.status, refused.error().as_str()), (413, "provider_request_too_large"));
    assert_eq!(provider.count(), 2);
    let status = server.status_v2().await;
    assert_eq!(status["quota"]["remaining"], 98);
    assert!(!status["tasks"]["everyday"]["capabilities"].as_array().unwrap().contains(&json!("analysis-backlog-v1")));
}

#[tokio::test]
async fn incomplete_oversized_and_redirected_upstream_answers_never_become_answers() {
    let json_type = [("Content-Type", "application/json")];
    for (upstream, code) in [
        (Upstream::new(200, &json_type, r#"{"status":"incomplete","output":[]}"#), "provider_invalid_response"),
        // The size is bounded even without a content length.
        (Upstream::new(200, &json_type, "x".repeat(65_537)), "upstream_response_too_large"),
        (Upstream::new(200, &[("Content-Type", "application/json"), ("Content-Length", "70000")], "{}"), "invalid_upstream_response"),
        // An oversized answer is rejected independently of the JSON size.
        (answer(&"a".repeat(16_001)), "invalid_upstream_answer"),
        (Upstream::new(302, &[("Location", "https://elsewhere.invalid")], ""), "provider_infrastructure")] {
        let provider = Provider::fixed(upstream);
        let response = serve(Config { retry_delay_ms: Some(1), ..config() }, &provider).await.post("/v1/ask", &payload()).await;
        assert_eq!((response.status, response.error().as_str()), (502, code));
    }
}

#[tokio::test]
async fn per_minute_limit_resets_on_next_bucket_without_retaining_user_data() {
    let (provider, clock) = (default_provider(), Clock::at(0));
    let server = clock.serve(Config { requests_per_minute: 1, ..config() }, &provider).await;
    assert_eq!(server.post("/v1/ask", &payload()).await.status, 200);
    let limited = server.post("/v1/ask", &payload()).await;
    assert_eq!((limited.status, limited.header("retry-after")), (429, Some("60")));
    clock.set(60_001);
    assert_eq!(server.post("/v1/ask", &payload()).await.status, 200);
    assert_eq!(provider.count(), 2);
}

#[tokio::test]
async fn daily_limit_remains_after_minute_bucket_changes() {
    let (provider, clock) = (default_provider(), Clock::at(0));
    let server = clock.serve(Config { requests_per_day: Some(1), ..config() }, &provider).await;
    assert_eq!(server.post("/v1/ask", &payload()).await.status, 200);
    clock.set(60_001);
    assert_eq!(server.post("/v1/ask", &payload()).await.status, 429);
    clock.set(86_400_001);
    assert_eq!(server.post("/v1/ask", &payload()).await.status, 200);
}

#[tokio::test]
async fn timeout_cancels_upstream_and_returns_a_sanitized_error() {
    let provider = Provider::fixed(Upstream::Hang);
    let response = serve(Config { upstream_timeout_ms: 20, ..config() }, &provider).await.post("/v1/ask", &payload()).await;
    assert_eq!(response.status, 504);
    assert_eq!(response.json(), json!({ "error": "upstream_timeout" }));
    assert_eq!(provider.cancelled(), 1);
}

#[test]
fn the_daily_caps_are_optional_but_a_configured_cap_must_be_a_bounded_positive_integer() {
    for variable in ["MIO_REQUESTS_PER_DAY", "MIO_TOKENS_PER_DAY"] {
        let cap = |value: &str| load(&[(variable, value)]).map(|config| if variable == "MIO_REQUESTS_PER_DAY" { config.requests_per_day } else { config.tokens_per_day });
        assert_eq!(load(&[]).unwrap().requests_per_day, None);
        for value in ["", "0"] {
            assert_eq!(cap(value), Ok(None));
        }
        assert_eq!(cap("2000"), Ok(Some(2_000)));
        for value in ["-1", "1.5", "many", "1000001"] {
            assert!(cap(value).is_err(), "{value}");
        }
    }
    assert!(load(&[("MIO_REQUESTS_PER_MINUTE", "61")]).is_err());
    let gateway = |config: Config| Gateway::new(config, Arc::new(Link(default_provider())));
    for requests_per_day in [0, 1_000_001] {
        assert!(gateway(Config { requests_per_day: Some(requests_per_day), ..config() }).is_err());
    }
    assert!(gateway(Config { requests_per_day: None, ..config() }).is_ok());
}

#[tokio::test]
async fn the_daily_token_cap_counts_reported_usage_and_blocks_before_a_provider_call_until_the_next_utc_day() {
    let (provider, clock) = (Provider::fixed(usage_completion(600)), Clock::at(NOON));
    let server = clock.serve(Config { tokens_per_day: Some(1_000), requests_per_day: None, ..config() }, &provider).await;
    assert_eq!(server.post("/v1/ask", &payload()).await.status, 200);
    assert_eq!(server.post("/v1/ask", &payload()).await.status, 200);
    clock.set(NOON + 60_001);
    let limited = server.post("/v1/ask", &payload()).await;
    assert_eq!((limited.status, limited.error().as_str()), (429, "local_token_limit"));
    assert_eq!(limited.header("retry-after"), Some("43140")); // 12 h minus the minute that passed
    assert_eq!(provider.count(), 2);
    clock.set(NOON + 12 * 3_600_000 + 1_000);
    assert_eq!(server.post("/v1/ask", &payload()).await.status, 200);
    assert_eq!(provider.count(), 3);
}

#[tokio::test]
async fn status_reports_the_token_quota_with_its_unit_and_never_a_request_count_as_tokens() {
    let (provider, clock) = (Provider::fixed(usage_completion(250)), Clock::at(NOON));
    let server = clock.serve(Config { tokens_per_day: Some(1_000), ..config() }, &provider).await;
    assert_eq!(server.post("/v1/ask", &payload()).await.status, 200);
    assert_eq!(server.status_v2().await["quota"], json!({ "limit": 1000, "remaining": 750, "resetAt": "2026-10-12T00:00:00.000Z", "unit": "tokens" }));
}

/// Ultrareview C1: Groq charges a cut-off, refused or rejected answer too, but only successful
/// generations reached `day_tokens`, so the phone saw more quota than was left.
#[tokio::test]
async fn failed_generations_that_reached_the_provider_still_count_against_the_day() {
    let truncated = Upstream::json(&json!({ "usage": { "prompt_tokens": 280, "completion_tokens": 20, "total_tokens": 300 },
        "choices": [{ "finish_reason": "length", "message": { "role": "assistant", "content": "{\"answer\":" } }] }));
    let refused = Upstream::json(&json!({ "usage": { "prompt_tokens": 90, "completion_tokens": 10, "total_tokens": 100 },
        "choices": [{ "finish_reason": "content_filter", "message": { "role": "assistant", "content": "" } }] }));
    let rejected = Upstream::json(&json!({ "usage": { "prompt_tokens": 40, "completion_tokens": 10, "total_tokens": 50 },
        "choices": [{ "finish_reason": "stop", "message": { "role": "assistant", "content": "{\"fel\":true}" } }] }));
    for (upstream, code, remaining) in [(truncated, "provider_truncated", 700), (refused, "provider_refusal", 900),
        (rejected, "invalid_upstream_answer", 950)] {
        let (provider, clock) = (Provider::fixed(upstream), Clock::at(NOON));
        let server = clock.serve(Config { tokens_per_day: Some(1_000), ..config() }, &provider).await;
        let failed = server.post("/v1/ask", &payload()).await;
        assert_eq!((failed.status, failed.error().as_str()), (502, code));
        assert_eq!(server.status_v2().await["quota"]["remaining"], remaining, "{code}");
    }
}

fn temporary_directory(name: &str) -> std::path::PathBuf {
    let directory = std::env::temp_dir().join(format!("mio-counters-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    std::fs::create_dir_all(&directory).unwrap();
    directory
}

#[tokio::test]
async fn counters_survive_a_gateway_restart_so_a_restart_cannot_reset_the_daily_allowance() {
    let path = temporary_directory("restart").join("counters.json");
    let gateway = |provider: &Arc<Provider>, time: i64| Gateway::new(Config { tokens_per_day: Some(1_000), ..config() }, Arc::new(Link(provider.clone())))
        .unwrap().with_store(Arc::new(FileCounterStore::new(&path))).with_clock(move || time);
    let first = Provider::fixed(usage_completion(900));
    assert_eq!(start(gateway(&first, NOON)).await.post("/v1/ask", &payload()).await.status, 200);
    let text = std::fs::read_to_string(&path).unwrap();
    let saved: Value = serde_json::from_str(&text).unwrap();
    let mut keys: Vec<&String> = saved.as_object().unwrap().keys().collect();
    keys.sort();
    assert_eq!(keys, ["day", "dayCount", "dayTokens", "minute", "minuteCount"]);
    assert_eq!(saved["dayTokens"], 900);
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    assert!(!text.contains("procent"));
    let second = Provider::fixed(usage_completion(900));
    let restarted = start(gateway(&second, NOON + 120_000)).await;
    assert_eq!(restarted.post("/v1/ask", &payload()).await.status, 200);
    assert_eq!(restarted.post("/v1/ask", &payload()).await.status, 429);
    assert_eq!(second.count(), 1);
}

#[test]
fn corrupt_or_foreign_counter_files_start_empty_instead_of_crashing_or_trusting_them() {
    let directory = temporary_directory("corrupt");
    let path = directory.join("counters.json");
    let mut negative = Counters::default().to_json();
    negative["dayTokens"] = json!(-5);
    let mut fractional = Counters::default().to_json();
    fractional["dayTokens"] = json!(1.5);
    for content in ["{broken".to_owned(), "[]".to_owned(), "{\"day\":1}".to_owned(), negative.to_string(), fractional.to_string()] {
        std::fs::write(&path, content).unwrap();
        assert_eq!(FileCounterStore::new(&path).load(), Counters::default());
    }
    assert_eq!(FileCounterStore::new(directory.join("missing.json")).load(), Counters::default());
    let stored = Counters { minute: 3, minute_count: 2, day: 1, day_count: 7, day_tokens: 900 };
    FileCounterStore::new(&path).save(&stored).unwrap();
    assert_eq!(FileCounterStore::new(&path).load(), stored);
}

#[tokio::test]
async fn a_failing_counter_store_blocks_provider_traffic_instead_of_spending_unrecorded_quota() {
    let provider = default_provider();
    let gateway = Gateway::new(config(), Arc::new(Link(provider.clone()))).unwrap().with_store(Arc::new(CountingStore::failing()));
    let response = start(gateway).await.post("/v1/ask", &payload()).await;
    assert_eq!(response.status, 503);
    assert_eq!(response.json(), json!({ "error": "budget_store_failed" }));
    assert_eq!(provider.count(), 0);
}

#[tokio::test]
async fn at_most_two_requests_generate_at_once_and_a_finished_one_frees_its_slot() {
    let release = Arc::new(Mutex::new(false));
    let hold = release.clone();
    let provider = Provider::new(move |_, _| if *hold.lock().unwrap() { answer("Svar.") } else { Upstream::Hang });
    let server = Arc::new(serve(Config { upstream_timeout_ms: 300, ..config() }, &provider).await);
    let pending: Vec<_> = (0..2).map(|_| { let server = server.clone(); tokio::spawn(async move { server.post("/v1/ask", &payload()).await.status }) }).collect();
    while provider.count() < 2 {
        tokio::task::yield_now().await;
    }
    let third = server.post("/v1/ask", &payload()).await;
    assert_eq!((third.status, third.error().as_str(), third.header("retry-after")), (429, "local_concurrency_limit", Some("60")));
    for task in pending {
        assert_eq!(task.await.unwrap(), 504);
    }
    *release.lock().unwrap() = true;
    assert_eq!(server.post("/v1/ask", &payload()).await.status, 200);
}
