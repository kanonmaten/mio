mod common;

use common::{MODEL, Provider, TOKEN, Upstream, env, serve, with};
use mio_gateway::adapters::{Finish, build_provider_request, normalize_provider_response};
use mio_gateway::analysis::{validate_ask_result, validate_lesson_payload, validate_lesson_result};
use mio_gateway::config::{Config, load_config};
use mio_gateway::model_profiles::{Incompatible, provider_profile};
use mio_gateway::task_profiles::resolve_task_profile;
use mio_gateway::tasks::{Mode, create_task_request};
use serde_json::{Value, json};

const ID: &str = "00000000-0000-0000-0000-000000000001:0";

fn payload() -> Value {
    json!({ "mode": "lesson", "timeZone": "Europe/Stockholm", "fragments": [{ "id": ID, "occurredAt": "2026-09-28T08:00:00Z",
        "text": "Procent betyder hundradelar. 20 procent av 50 är 0,20 gånger 50 = 10. Gör uppgift 7 till fredag." }] })
}

fn notes() -> Value {
    json!({ "candidates": [{ "kind": "task", "title": "Gör uppgift 7", "body": "Till fredag.", "scheduledAt": null,
            "sourceIDs": [ID], "evidence": "Gör uppgift 7 till fredag." }],
        "sections": [{ "heading": "Procent och beräkning",
            "body": "Procent betyder hundradelar.\n1. Skriv 20 % som 0,20.\n2. Multiplicera med 50.\n3. Resultatet är 10.",
            "sourceIDs": [ID], "evidence": "20 procent av 50 är 0,20 gånger 50 = 10." }],
        "uncertainties": [] })
}

fn config_for(model: &str) -> Config {
    load_config(&env(&[("MIO_AI_MODEL", model), ("GROQ_API_KEY", "fixture-key"),
        ("OPENAI_API_KEY", "must-not-use-other-vendor-key"), ("MIO_GATEWAY_TOKEN", TOKEN)])).unwrap()
}

fn envelope(value: &Value) -> Value {
    json!({ "choices": [{ "finish_reason": "stop", "message": { "role": "assistant", "content": value.to_string() } }] })
}

#[test]
fn groq_correct_secret_endpoint_strict_schema_temperature_and_reasoning_policy() {
    let config = config_for(MODEL);
    assert_eq!((config.provider.as_str(), config.api_key.as_str()), ("groq", "fixture-key"));
    for mode in [Mode::Ask, Mode::Analyze, Mode::Lesson] {
        let request = build_provider_request(&config, &create_task_request(mode, &payload())).unwrap();
        assert_eq!(request.url, "https://api.groq.com/openai/v1/chat/completions");
        assert_eq!(request.body["temperature"], 0);
        assert_eq!(request.body["model"], MODEL);
        assert_eq!(request.body["reasoning_effort"], "none");
        assert_eq!(request.body["stream"], false);
        assert_eq!(request.header("Authorization").unwrap(), "Bearer fixture-key");
        let serialized = format!("{request:?} {config:?}");
        for private in [TOKEN, "must-not-use-other-vendor-key", "fixture-key"] {
            assert!(!serialized.contains(private) && !request.body.to_string().contains(private));
        }
        let format = &request.body["response_format"]["json_schema"];
        assert_eq!(request.body["response_format"]["type"], "json_schema");
        assert_eq!(format["strict"], true);
        assert_eq!(format["schema"]["additionalProperties"], false);
        if mode == Mode::Lesson {
            assert_eq!(format["schema"]["properties"]["candidates"]["items"]["properties"]["kind"]["enum"], json!(["plan", "task"]));
        }
        let names: Vec<&String> = format["schema"]["properties"].as_object().unwrap().keys().collect();
        assert_eq!(format["schema"]["required"], json!(names));
        let normalized = normalize_provider_response(&envelope(&notes()), &request.profile, &|_| None).unwrap();
        assert_eq!(normalized.text, Some(notes().to_string()));
    }
}

#[test]
fn only_the_reviewed_groq_model_is_accepted_and_others_fail_before_a_request_is_built() {
    for (provider, model) in [("groq", "openai/gpt-oss-20b"), ("groq", "invented"), ("groq", "qwen/qwen3-32b"),
        ("openai", "gpt-6-luna"), ("gemini", "gemini-2.5-flash"), ("anthropic", "claude-haiku-4-5"),
        ("openrouter", "openai/gpt-4.1"), ("nvidia", "deepseek-ai/deepseek-v4.1-flash"), ("custom", "host/model"),
        ("groq", "gsk_secretlooking"), ("groq", "https://evil.example/model"), ("groq", "")] {
        assert_eq!(provider_profile(provider, model, None), Err(Incompatible::Model), "{provider} {model}");
    }
    assert_eq!(provider_profile("groq", MODEL, Some(&json!({ "route": "x" }))), Err(Incompatible::Options));
    assert!(!provider_profile("groq", MODEL, None).unwrap().contract_review.live_tested);
}

#[test]
fn removed_provider_environment_variables_are_ignored_and_never_reused_as_groq_credentials_or_model() {
    let base = [("MIO_GATEWAY_TOKEN", TOKEN), ("OPENAI_API_KEY", "fixture"), ("MIO_OPENAI_MODEL", "gpt-6-luna")];
    let load = |extra: &[(&str, &str)]| load_config(&env(&[&base[..], extra].concat())).unwrap();
    let missing_key = load(&[("MIO_AI_MODEL", MODEL)]);
    assert_eq!((missing_key.provider.as_str(), missing_key.api_key.as_str()), ("groq", ""));
    assert!(!resolve_task_profile(&missing_key, "ask").configured);
    let missing_model = load(&[("GROQ_API_KEY", "fixture")]);
    assert_eq!(missing_model.model, "");
    assert!(!resolve_task_profile(&missing_model, "ask").configured);
    assert!(resolve_task_profile(&load(&[("GROQ_API_KEY", "fixture"), ("MIO_AI_MODEL", MODEL)]), "ask").configured);
    assert!(!resolve_task_profile(&load(&[("MIO_AI_PROVIDER", "openai"), ("GROQ_API_KEY", "fixture"), ("MIO_AI_MODEL", MODEL)]), "ask").configured);
}

#[test]
fn the_chat_adapter_rejects_truncation_refusals_tools_and_observable_reasoning() {
    let profile = provider_profile("groq", MODEL, None).unwrap();
    let completed = |data: &Value| normalize_provider_response(data, &profile, &|_| None).is_ok_and(|result| result.finish == Finish::Completed);
    assert!(completed(&envelope(&notes())));
    for reason in ["length", "content_filter"] {
        let mut data = envelope(&notes());
        data["choices"][0]["finish_reason"] = json!(reason);
        assert!(!completed(&data), "{reason}");
    }
    let mut data = envelope(&notes());
    data["usage"] = json!({ "completion_tokens_details": { "reasoning_tokens": 5 } });
    assert!(!completed(&data));
    for patch in [json!({ "refusal": "No" }), json!({ "tool_calls": [{}] }), json!({ "function_call": {} }),
        json!({ "reasoning_content": "thought" }), json!({ "reasoning": "thought" })] {
        let mut data = envelope(&notes());
        data["choices"][0]["message"] = with(&data["choices"][0]["message"], patch.clone());
        assert!(!completed(&data), "{patch}");
    }
    assert!(!completed(&json!({ "choices": [] })));
}

#[test]
fn detailed_notes_retain_worked_steps_and_exact_grounding_while_invented_evidence_and_notes_as_homework_fail() {
    assert!(validate_lesson_payload(&payload()).is_ok());
    assert_eq!(validate_lesson_result(&notes(), &payload()).unwrap(), notes());
    let with_section = |patch: Value| with(&notes(), json!({ "sections": [with(&notes()["sections"][0], patch)] }));
    // A section is the notes themselves: one that cannot be grounded rejects the whole part.
    for patch in [json!({ "evidence": "påhittat" }), json!({ "heading": "" }), json!({ "body": "x".repeat(8001) }), json!({ "slides": [] })] {
        assert!(validate_lesson_result(&with_section(patch), &payload()).is_err());
    }
    let repaired = validate_lesson_result(&with_section(json!({ "sourceIDs": [ID, ID, "unknown"] })), &payload()).unwrap();
    assert_eq!(repaired["sections"][0]["sourceIDs"], json!([ID]));
    // Notes offered as homework are dropped; the sections stay.
    let homework = with(&notes(), json!({ "candidates": [with(&notes()["candidates"][0], json!({ "kind": "note" }))] }));
    let cleaned = validate_lesson_result(&homework, &payload()).unwrap();
    assert_eq!((&cleaned["candidates"], &cleaned["sections"]), (&json!([]), &notes()["sections"]));
    assert!(validate_lesson_payload(&with(&payload(), json!({ "mode": "everyday" }))).is_err());
    let long = with(&payload(), json!({ "fragments": [with(&payload()["fragments"][0], json!({ "text": "å".repeat(1751) }))] }));
    assert!(validate_lesson_payload(&long).is_err());
    assert!(validate_ask_result(&json!({ "answer": "test", "action": "create" })).is_err());
    assert!(validate_ask_result(&json!({ "answer": "" })).is_err());
}

fn fixture_config(model: &str, interval: u64) -> Config {
    Config { requests_per_minute: 60, lesson_interval_seconds: Some(interval), ..config_for(model) }
}

#[tokio::test]
async fn lesson_http_contract_authenticates_validates_and_adds_server_owned_provenance_and_pacing() {
    let provider = Provider::fixed(Upstream::json(&envelope(&notes())));
    let server = serve(fixture_config(MODEL, 120), &provider).await;
    assert_eq!(server.post_with("/v1/lesson-notes", &payload(), &[("Authorization", "Bearer wrong")]).await.status, 401);
    assert_eq!(server.post("/v1/lesson-notes", &with(&payload(), json!({ "mode": "everyday" }))).await.status, 400);
    assert_eq!(provider.count(), 0);
    let response = server.post("/v1/lesson-notes", &payload()).await;
    assert_eq!(response.status, 200);
    let body = response.json();
    assert_eq!((&body["sections"], &body["candidates"]), (&notes()["sections"], &notes()["candidates"]));
    assert_eq!(body["metadata"], json!({ "provider": "groq", "model": MODEL, "promptVersion": "2026-10-13.2", "lessonIntervalSeconds": 120 }));
    assert_eq!(provider.count(), 1);
}

#[tokio::test]
async fn incompatible_model_fails_locally_without_spending_a_request() {
    let provider = Provider::fixed(Upstream::json(&envelope(&notes())));
    let response = serve(fixture_config("openai/gpt-oss-20b", 60), &provider).await.post("/v1/lesson-notes", &payload()).await;
    assert_eq!((response.status, response.error().as_str()), (422, "task_configuration_invalid"));
    assert_eq!(provider.count(), 0);
}

#[tokio::test]
async fn upstream_rejection_is_a_compatibility_error_not_permission_to_remove_strict_parameters() {
    let provider = Provider::fixed(Upstream::new(400, &[], "private details"));
    let response = serve(fixture_config(MODEL, 60), &provider).await.post("/v1/lesson-notes", &payload()).await;
    assert_eq!((response.status, response.error().as_str()), (422, "provider_parameters"));
    assert_eq!(provider.count(), 1);
}

#[tokio::test]
async fn quota_retry_after_is_bounded_forwarded_and_never_automatically_retried() {
    let provider = Provider::fixed(Upstream::new(429, &[("Retry-After", "123")], "private quota data"));
    let response = serve(fixture_config(MODEL, 60), &provider).await.post("/v1/lesson-notes", &payload()).await;
    assert_eq!((response.status, response.error().as_str()), (429, "provider_quota"));
    assert_eq!(response.header("retry-after"), Some("123"));
    assert_eq!(provider.count(), 1);
}
