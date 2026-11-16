mod common;

use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use common::{CountingStore, Link, MODEL, Provider, TOKEN, Upstream, start};
use mio_gateway::adapters::{Finish, Normalized, Provenance, Usage};
use mio_gateway::config::Config;
use mio_gateway::generation::generation_metadata_headers;
use mio_gateway::server::Gateway;
use serde_json::json;
use tokio::io::AsyncWriteExt;

fn config() -> Config {
    Config { api_key: "fixture-key".to_owned(), gateway_token: TOKEN.to_owned(), model: MODEL.to_owned(), requests_per_minute: 60,
        requests_per_day: Some(100), upstream_timeout_ms: 45, body_timeout_ms: 45, ..Config::default() }
}

const BODY: &str = r#"{"question":"Syntetiskt prov","context":[]}"#;

fn head(extra: &str) -> String {
    format!("POST /v1/ask HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {TOKEN}\r\nContent-Type: application/json\r\n{extra}\r\n")
}

fn completion() -> Upstream {
    Upstream::completion(&json!({ "answer": "Syntetiskt svar" }))
}

async fn until(condition: impl Fn() -> bool) {
    tokio::time::timeout(Duration::from_secs(5), async {
        while !condition() {
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
    }).await.expect("the condition was never reached");
}

#[tokio::test]
async fn a_provider_call_still_pending_at_the_deadline_is_cancelled() {
    let provider = Provider::fixed(Upstream::Hang);
    let server = common::serve(config(), &provider).await;
    let response = server.post("/v1/ask", &serde_json::from_str(BODY).unwrap()).await;
    assert_eq!((response.status, response.error().as_str()), (504, "upstream_timeout"));
    assert_eq!(provider.cancelled(), 1);
}

#[tokio::test]
async fn a_provider_body_that_never_arrives_is_cancelled_at_the_deadline() {
    let provider = Provider::fixed(Upstream::HangBody);
    let server = common::serve(config(), &provider).await;
    let response = server.post("/v1/ask", &serde_json::from_str(BODY).unwrap()).await;
    assert_eq!((response.status, response.error().as_str()), (504, "upstream_timeout"));
    assert_eq!(provider.cancelled(), 1);
}

#[tokio::test]
async fn slow_chunked_request_body_has_its_separate_deadline_and_never_reserves_quota() {
    let provider = Provider::fixed(completion());
    let store = Arc::new(CountingStore::default());
    let server = start(Gateway::new(config(), Arc::new(Link(provider.clone()))).unwrap().with_store(store.clone())).await;
    let mut stream = server.connect().await;
    stream.write_all(format!("{}c\r\n{{\"question\":\r\n", head("Transfer-Encoding: chunked\r\n")).as_bytes()).await.unwrap();
    let response = common::read_reply(&mut stream).await;
    assert_eq!(response.status, 408);
    assert_eq!(response.json(), json!({ "error": "request_timeout" }));
    assert_eq!((store.saves.load(Ordering::SeqCst), provider.count()), (0, 0));
}

/// A client that disappears cancels the work in progress and frees its slot for the next request.
async fn disconnect_during(stage: &str) {
    let first = match stage { "fetch" => Upstream::Hang, "response" => Upstream::HangBody, _ => completion() };
    let provider = Provider::new(move |index, _| if index == 0 { first.clone() } else { completion() });
    let server = common::serve(Config { upstream_timeout_ms: 2_000, body_timeout_ms: 2_000, requests_per_minute: 60, ..config() }, &provider).await;
    let mut stream = server.connect().await;
    if stage == "body" {
        stream.write_all(format!("{}c\r\n{{\"question\":\r\n", head("Transfer-Encoding: chunked\r\n")).as_bytes()).await.unwrap();
        tokio::time::sleep(Duration::from_millis(20)).await;
    } else {
        stream.write_all(format!("{}{BODY}", head(&format!("Content-Length: {}\r\n", BODY.len()))).as_bytes()).await.unwrap();
        until(|| provider.count() == 1).await;
    }
    drop(stream);
    if stage != "body" {
        // The pending provider call (or its unread body) is dropped long before the deadline.
        until(|| provider.cancelled() == 1).await;
    }
    for _ in 0..3 {
        assert_eq!(server.post("/v1/ask", &serde_json::from_str(BODY).unwrap()).await.status, 200, "{stage}");
    }
    assert_eq!(provider.count(), if stage == "body" { 3 } else { 4 });
}

#[tokio::test]
async fn disconnect_during_the_request_body_cancels_work_and_frees_resources() {
    disconnect_during("body").await;
}

#[tokio::test]
async fn disconnect_during_the_provider_call_cancels_work_and_frees_resources() {
    disconnect_during("fetch").await;
}

#[tokio::test]
async fn disconnect_during_the_provider_response_cancels_work_and_frees_resources() {
    disconnect_during("response").await;
}

#[test]
fn public_generation_metadata_drops_urls_and_credential_shaped_identifiers() {
    let normalized = |model: &str, request_id: &str, usage: Option<Usage>| Normalized { text: None, finish: Finish::Completed, refusal: false,
        requested_model: MODEL.to_owned(), returned_model: Some(model.to_owned()), usage,
        provenance: Some(Provenance { response_id: None, request_id: Some(request_id.to_owned()) }) };
    for value in ["https://private.example/model", "sk-private", "sk_private", "gsk_private", "AIzaPrivate", "SK_private", "GSK_private", "aizaPrivate"] {
        assert_eq!(generation_metadata_headers(&normalized(value, value, None)), []);
    }
    let usage = Usage { input_tokens: Some(4), output_tokens: Some(2), reasoning_tokens: Some(0), ..Usage::default() };
    assert_eq!(generation_metadata_headers(&normalized("model-1", "req_1", Some(usage))), [
        ("X-Mio-Returned-Model", "model-1".to_owned()), ("X-Mio-Upstream-Request-ID", "req_1".to_owned()),
        ("X-Mio-Usage-Input-Tokens", "4".to_owned()), ("X-Mio-Usage-Output-Tokens", "2".to_owned()), ("X-Mio-Usage-Reasoning-Tokens", "0".to_owned())]);
}

#[tokio::test]
async fn oversized_provider_error_envelopes_keep_their_quota_category_and_retry_after() {
    let provider = Provider::fixed(Upstream::new(429, &[("Content-Type", "application/json"), ("Retry-After", "7")], "x".repeat(70_000)));
    let response = common::serve(config(), &provider).await.post("/v1/ask", &serde_json::from_str(BODY).unwrap()).await;
    assert_eq!((response.status, response.error().as_str(), response.header("retry-after")), (429, "provider_quota", Some("7")));
}

#[tokio::test]
async fn a_request_head_larger_than_the_limit_is_refused_before_any_work() {
    let provider = Provider::fixed(completion());
    let server = common::serve(config(), &provider).await;
    let mut stream = server.connect().await;
    let _ = stream.write_all(head(&format!("X-Padding: {}\r\n", "x".repeat(9_000))).as_bytes()).await;
    assert_eq!(common::read_reply(&mut stream).await.status, 431);
    assert_eq!(provider.count(), 0);
}
