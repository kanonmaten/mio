mod common;

use common::{Provider, Upstream, authorized, serve, with, without};
use mio_gateway::adapters::build_provider_request;
use mio_gateway::analysis::{analysis_format, validate_analysis_v2_payload, validate_analysis_v2_result};
use mio_gateway::config::Config;
use mio_gateway::tasks::{Mode, create_task_request};
use serde_json::{Value, json};

const OLD: &str = "00000000-0000-0000-0000-000000000001:0";
const NEW: &str = "00000000-0000-0000-0000-000000000002:0";
const DECISION: &str = "00000000-0000-0000-0000-000000000003";
const OTHER_DECISION: &str = "00000000-0000-0000-0000-000000000004";

fn payload() -> Value {
    json!({ "mode": "everyday", "timeZone": "Europe/Stockholm",
        "fragments": [{ "id": NEW, "text": "nej, torsdag i stället.", "occurredAt": "2026-09-30T12:01:00Z" }],
        "contextFragments": [{ "id": OLD, "text": "Vi ses på biblioteket på tisdag klockan 15.", "occurredAt": "2026-09-30T12:00:00Z" }],
        "priorDecisions": [{ "id": DECISION, "kind": "plan", "sourceIDs": [OLD], "isOpen": true }], "contextLimited": false })
}

fn candidate() -> Value {
    json!({ "kind": "plan", "title": "Biblioteket", "body": "Kontrollera datum.", "scheduledAt": null,
        "sourceIDs": [OLD, NEW], "evidence": "nej, torsdag i stället.", "replacesID": DECISION })
}

fn result() -> Value {
    json!({ "candidates": [candidate()], "highlights": [], "uncertainties": [] })
}

fn numbered(id: &str, index: usize) -> String {
    id.replace(":0", &format!(":{index}"))
}

#[test]
fn v2_payload_rejects_unbounded_context_overlapping_sources_invalid_decisions_and_unknown_fields() {
    assert!(validate_analysis_v2_payload(&payload()).is_ok());
    let context = payload()["contextFragments"][0].clone();
    let decision = payload()["priorDecisions"][0].clone();
    let fragment = payload()["fragments"][0].clone();
    let fragments = |count: usize, text: &str| (0..count)
        .map(|index| with(&fragment, json!({ "id": numbered(NEW, index), "text": text }))).collect::<Vec<_>>();
    for patch in [json!({ "mode": "lesson" }), json!({ "contextLimited": "yes" }), json!({ "unexpected": true }), json!({ "fragments": [] }),
        json!({ "contextFragments": [with(&context, json!({ "id": NEW }))] }),
        json!({ "contextFragments": [with(&context, json!({ "text": "å".repeat(2001) }))] }),
        json!({ "contextFragments": [with(&context, json!({ "text": "å".repeat(1001) })),
            with(&context, json!({ "id": numbered(OLD, 1), "text": "å".repeat(1000) }))] }),
        json!({ "priorDecisions": vec![decision.clone(); 13] }), json!({ "priorDecisions": [decision, decision] }),
        json!({ "priorDecisions": [with(&decision, json!({ "id": "invalid" }))] }),
        json!({ "priorDecisions": [with(&decision, json!({ "sourceIDs": [NEW] }))] }),
        json!({ "priorDecisions": [with(&decision, json!({ "sourceIDs": [] }))] }),
        json!({ "priorDecisions": [with(&decision, json!({ "sourceIDs": [OLD, OLD] }))] }),
        json!({ "priorDecisions": [with(&decision, json!({ "isOpen": 1 }))] }),
        json!({ "priorDecisions": [with(&decision, json!({ "kind": "memory" }))] }),
        json!({ "fragments": fragments(16, "nej, torsdag i stället.") }), json!({ "fragments": fragments(5, &"ö".repeat(1700)) })] {
        assert!(validate_analysis_v2_payload(&with(&payload(), patch.clone())).is_err(), "{}", patch.to_string().chars().take(120).collect::<String>());
    }
    // A backlog batch carries twelve new sources beside the context.
    assert!(validate_analysis_v2_payload(&with(&payload(), json!({ "fragments": fragments(12, &"å".repeat(450)) }))).is_ok());
}

#[test]
fn v2_candidates_require_new_evidence_sources_and_explicit_unambiguous_open_replacement() {
    assert_eq!(validate_analysis_v2_result(&result(), &payload()).unwrap(), result());
    let candidates = |value: &Value, request: &Value| validate_analysis_v2_result(value, request).unwrap()["candidates"].clone();
    let patched = |patch: Value| with(&result(), json!({ "candidates": [with(&candidate(), patch)] }));
    for patch in [json!({ "sourceIDs": [OLD], "evidence": "Vi ses" }), json!({ "replacesID": null }), json!({ "replacesID": "invalid" }),
        json!({ "replacesID": OTHER_DECISION }), json!({ "kind": "task" }), json!({ "sourceIDs": [NEW] }), json!({ "evidence": "never said" })] {
        assert_eq!(candidates(&patched(patch.clone()), &payload()), json!([]), "{patch}");
    }
    let missing = with(&result(), json!({ "candidates": [without(&candidate(), "replacesID")] }));
    assert!(validate_analysis_v2_result(&missing, &payload()).is_err());
    // A closed decision is never revived and a shared source never picks a decision.
    let decision = payload()["priorDecisions"][0].clone();
    let closed = with(&payload(), json!({ "priorDecisions": [with(&decision, json!({ "isOpen": false }))] }));
    assert_eq!(candidates(&result(), &closed), json!([]));
    let shared = with(&payload(), json!({ "priorDecisions": [decision, with(&decision, json!({ "id": OTHER_DECISION }))] }));
    assert_eq!(candidates(&result(), &shared), json!([]));
    // One decision is replaced by at most one candidate; the first stays.
    assert_eq!(candidates(&with(&result(), json!({ "candidates": [candidate(), candidate()] })), &payload()), json!([candidate()]));
    let separate = patched(json!({ "sourceIDs": [NEW], "replacesID": null }));
    assert_eq!(candidates(&separate, &payload()).as_array().unwrap().len(), 1);
    assert_eq!(candidates(&patched(json!({ "replacesID": null })), &with(&payload(), json!({ "priorDecisions": [] }))).as_array().unwrap().len(), 1);
    assert_eq!(candidates(&separate, &closed).as_array().unwrap().len(), 1);
}

fn fixture_config() -> Config {
    Config { api_key: "fixture-key".to_owned(), requests_per_minute: 6, ..common::config() }
}

#[test]
fn v2_upstream_receives_its_strict_replacement_schema_while_legacy_schema_stays_unchanged() {
    let request = build_provider_request(&fixture_config(), &create_task_request(Mode::AnalyzeV2, &payload())).unwrap();
    let format = &request.body["response_format"]["json_schema"];
    assert_eq!(format["name"], "mio_analysis_v2");
    let item = &format["schema"]["properties"]["candidates"]["items"];
    assert_eq!(item["additionalProperties"], false);
    assert!(item["required"].as_array().unwrap().contains(&json!("replacesID")));
    assert_eq!(item["properties"]["replacesID"]["type"], json!(["string", "null"]));
    assert_eq!(serde_json::from_str::<Value>(request.body["messages"][1]["content"].as_str().unwrap()).unwrap(), payload());
    assert_eq!(request.body["reasoning_effort"], "none");
    assert_eq!(request.body["temperature"], 0);
    assert!(analysis_format()["schema"]["properties"]["candidates"]["items"]["properties"].get("replacesID").is_none());
}

#[tokio::test]
async fn v2_http_endpoint_validates_before_quota_and_returns_sanitized_metadata_on_success_and_failure() {
    let provider = Provider::fixed(Upstream::completion(&result()));
    let server = serve(fixture_config(), &provider).await;
    let wrong = [("Authorization", "Bearer wrong"), ("X-Mio-Request-ID", "untrusted")];
    assert_eq!(server.post_with("/v2/analyze", &payload(), &wrong).await.status, 401);
    assert_eq!(server.post("/v2/analyze", &with(&payload(), json!({ "contextLimited": 5 }))).await.status, 400);
    assert_eq!(provider.count(), 0);
    let success = server.post_with("/v2/analyze", &payload(), &[("X-Mio-Request-ID", "untrusted")]).await;
    assert_eq!(success.status, 200);
    assert_eq!(success.json(), result());
    for response in [success, server.post_with("/v2/analyze", &payload(), &wrong).await] {
        assert_eq!(response.header("x-mio-release"), Some(mio_gateway::status::RELEASE));
        assert_eq!(response.header("x-mio-provider"), Some("groq"));
        assert_eq!(response.header("x-mio-model"), Some(common::MODEL));
        assert_eq!(response.header("x-mio-prompt-version"), Some("2026-10-13.2"));
        let id = response.header("x-mio-request-id").unwrap();
        assert!(id.len() == 36 && id != "untrusted" && id.chars().all(|character| character.is_ascii_hexdigit() || character == '-'), "{id}");
    }
}

#[tokio::test]
async fn status_authenticates_without_model_calls_or_budget_and_advertises_implemented_context_contract() {
    let provider = Provider::fixed(Upstream::completion(&result()));
    let server = serve(fixture_config(), &provider).await;
    assert_eq!(server.get("/v1/status", &[("Authorization", "Bearer wrong".to_owned())]).await.status, 401);
    let response = server.get("/v1/status", &authorized()).await;
    assert_eq!(response.status, 200);
    assert_eq!(response.json(), json!({ "protocolVersion": 2, "release": mio_gateway::status::RELEASE, "configured": true,
        "provider": "groq", "model": common::MODEL, "promptVersion": "2026-10-13.2",
        "capabilities": ["analysis-context-v2", "ask-v1", "analysis-v1", "lesson-notes-v1"] }));
    assert_eq!(provider.count(), 0);
}

#[tokio::test]
async fn v2_invalid_upstream_replacement_cannot_escape_as_a_proposal() {
    let answer = with(&result(), json!({ "candidates": [with(&candidate(), json!({ "replacesID": null }))] }));
    let response = serve(fixture_config(), &Provider::fixed(Upstream::completion(&answer))).await.post("/v2/analyze", &payload()).await;
    assert_eq!(response.status, 200);
    assert_eq!(response.json(), json!({ "candidates": [], "highlights": [], "uncertainties": [] }));
}

/// Ultrareview C4: the six-candidate cap ran before the v2 rules, so candidates the rules then
/// dropped took places that valid candidates further down should have had.
#[test]
fn v2_rules_run_before_the_six_candidate_cap() {
    let breaking = with(&candidate(), json!({ "sourceIDs": [OLD], "evidence": "Vi ses", "replacesID": null }));
    let valid = |index: usize| with(&candidate(), json!({ "title": format!("Förslag {index}"), "sourceIDs": [NEW], "replacesID": null }));
    let mut items = vec![breaking.clone(), breaking];
    items.extend((0..6).map(valid));
    let answer = with(&result(), json!({ "candidates": items }));
    let kept = validate_analysis_v2_result(&answer, &payload()).unwrap()["candidates"].clone();
    assert_eq!(kept, json!((0..6).map(valid).collect::<Vec<_>>()));
}
