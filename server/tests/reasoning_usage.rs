//! Mistral after the grilling (2026-11-19/20), without network: Large 4 reasons only for
//! lessons and its thinking is dropped unread, Small 4 keeps reasoning off, and the monthly usage
//! counter behind Mio Kontroll's credit meter.

mod common;

use std::sync::Arc;

use common::{Link, Provider, TOKEN, Upstream, authorized, env, start};
use mio_gateway::adapters::{Finish, build_for_profile, normalize_provider_response, response_usage};
use mio_gateway::config::{Config, LESSON_REASONING_MAX_OUTPUT_TOKENS, LESSON_REASONING_TIMEOUT_MS, load_config};
use mio_gateway::generation::{Spent, execute_generation, trial_call};
use mio_gateway::model_profiles::{CANDIDATE_MODELS, REASONING_LEVELS, candidate_profile, reasoning_levels};
use mio_gateway::server::Gateway;
use mio_gateway::status::{configuration_revision, gateway_status_v2};
use mio_gateway::task_profiles::resolve_task_profile;
use mio_gateway::tasks::{Mode, create_task_request};
use mio_gateway::tools::{mistral_gateway_env, reviewed_models, trial};
use mio_gateway::usage::{FileUsageStore, Ledger, Loaded, UsageStore, month_of};
use serde_json::{Value, json};

const SMALL: &str = "mistral-small-2603";
const LARGE: &str = "mistral-large-4-0";
const KEY: &str = "fixturemistralkey0123456789abcdef";
const OLD: &str = "00000000-0000-0000-0000-000000000001:0";
/// Stands in for thinking text: it must never leave the adapter.
const THOUGHT: &str = "PRIVAT_TANKE_SOM_ALDRIG_FAR_SPARAS";
const NOVEMBER: i64 = 1_795_176_000_000; // 2026-11-20T12:00:00Z

fn mistral_env(extra: &[(&'static str, &'static str)]) -> Vec<(&'static str, &'static str)> {
    let mut pairs = vec![("MIO_AI_PROVIDER", "mistral"), ("MIO_AI_MODEL", SMALL), ("MISTRAL_API_KEY", KEY),
        ("MIO_GATEWAY_TOKEN", TOKEN), ("MIO_AI_TASK_PROFILES", r#"{"lesson":{"model":"mistral-large-4-0"}}"#),
        ("MIO_APPROVED_CANDIDATES", "mistral=mistral-small-2603,mistral=mistral-large-4-0")];
    pairs.extend_from_slice(extra);
    pairs
}

fn mistral_config() -> Config {
    load_config(&env(&mistral_env(&[]))).unwrap()
}

fn lesson_payload() -> Value {
    json!({ "mode": "lesson", "timeZone": "Europe/Stockholm", "fragments": [{ "id": OLD, "occurredAt": "2026-09-28T08:00:00Z",
        "text": "Procent betyder hundradelar. 20 procent av 50 är 0,20 gånger 50 = 10. Gör uppgift 7 till fredag." }] })
}

fn lesson_answer() -> Value {
    json!({ "candidates": [{ "kind": "task", "title": "Gör uppgift 7", "body": "Till fredag.", "scheduledAt": null,
            "sourceIDs": [OLD], "evidence": "Gör uppgift 7 till fredag." }],
        "sections": [{ "heading": "Procent", "body": "Procent betyder hundradelar.", "sourceIDs": [OLD],
            "evidence": "20 procent av 50 är 0,20 gånger 50 = 10." }],
        "uncertainties": [] })
}

fn thinking() -> Value {
    json!({ "type": "thinking", "thinking": [{ "type": "text", "text": THOUGHT }] })
}

fn chat(content: Value, finish: &str, usage: Value) -> Value {
    json!({ "id": "cmpl-1", "model": LARGE, "choices": [{ "index": 0, "finish_reason": finish,
        "message": { "role": "assistant", "content": content } }], "usage": usage })
}

#[test]
fn large_4_reasons_at_medium_with_room_for_thinking_and_keeps_the_schema_request() {
    let profile = candidate_profile("mistral", LARGE).unwrap();
    assert_eq!((profile.reasoning.level(), profile.schema_dialect), ("medium", "json-schema"));
    let mut generation = create_task_request(Mode::Lesson, &lesson_payload());
    generation.max_output_tokens = mio_gateway::config::output_limit("lesson", &profile, generation.max_output_tokens);
    assert_eq!(generation.max_output_tokens, LESSON_REASONING_MAX_OUTPUT_TOKENS);
    let request = build_for_profile(profile, KEY, &generation).unwrap();
    assert_eq!(request.body["model"], LARGE);
    assert_eq!(request.body["reasoning_effort"], "medium");
    assert_eq!(request.body["max_tokens"], 12_000);
    // The schema request is sent as before; Mistral's answer is validated, not trusted.
    assert_eq!(request.body["response_format"]["type"], "json_schema");
    assert_eq!(request.body["response_format"]["json_schema"]["strict"], true);
    assert_eq!(request.body["response_format"]["json_schema"]["schema"], generation.structured_output["schema"]);
    // Small 4 keeps reasoning off and the lesson's ordinary budget.
    let small = candidate_profile("mistral", SMALL).unwrap();
    let lesson = create_task_request(Mode::Lesson, &lesson_payload());
    assert_eq!(mio_gateway::config::output_limit("lesson", &small, lesson.max_output_tokens), 3_000);
    let request = build_for_profile(small, KEY, &lesson).unwrap();
    assert_eq!((request.body["reasoning_effort"].clone(), request.body["max_tokens"].clone()), (json!("none"), json!(3_000)));
}

#[test]
fn a_model_that_reasons_gets_its_providers_temperature_and_a_plain_one_gets_zero() {
    let lesson = create_task_request(Mode::Lesson, &lesson_payload());
    // Every candidate that always reasons, directly and through OpenRouter: no provider documents a
    // value for them, and Gemini 3.6+ asks for the parameter to be removed (MIO-43).
    for (provider, model) in [("mistral", LARGE), ("openai", "gpt-6.2-sol"), ("gemini", "gemini-3.8-flash"),
        ("openrouter", "mistralai/mistral-large-4-0"), ("openrouter", "google/gemini-3.8-flash")] {
        let profile = candidate_profile(provider, model).unwrap();
        assert!(profile.reasoning.reasons() && !profile.temperature, "{provider} {model}");
        let request = build_for_profile(profile, KEY, &lesson).unwrap();
        assert!(request.body.get("temperature").is_none(), "{provider} {model}");
    }
    // A model with reasoning off keeps temperature 0, for lessons too.
    for (provider, model) in [("mistral", SMALL), ("openai", "gpt-6-luna"), ("gemini", "gemini-2.5-flash-lite"), ("openrouter", "qwen/qwen3.8-27b")] {
        let request = build_for_profile(candidate_profile(provider, model).unwrap(), KEY, &lesson).unwrap();
        assert_eq!(request.body["temperature"], 0, "{provider} {model}");
    }
    // The panel's list says the same.
    let listed: Value = serde_json::from_str(&reviewed_models()).unwrap();
    let temperature = |model: &str| listed["candidates"].as_array().unwrap().iter()
        .find(|entry| entry["model"] == model).map(|entry| entry["temperature"].clone()).unwrap();
    assert_eq!((temperature(LARGE), temperature(SMALL)), (json!("provider-default"), json!("0")));
}

#[test]
fn every_pair_that_reasons_has_reviewed_levels_including_its_own() {
    for candidate in CANDIDATE_MODELS.iter().filter(|candidate| candidate.reasoning.reasons()) {
        let levels = reasoning_levels(candidate.provider, candidate.model);
        assert!(levels.contains(&candidate.reasoning.level()), "{} {}", candidate.provider, candidate.model);
    }
    assert!(REASONING_LEVELS.iter().all(|(provider, model, _)| CANDIDATE_MODELS.iter()
        .any(|candidate| candidate.provider == *provider && candidate.model == *model && candidate.reasoning.reasons())));
    assert!(reasoning_levels("mistral", SMALL).is_empty());
}

#[test]
fn the_chosen_lesson_level_is_sent_published_and_part_of_the_revision() {
    let high = load_config(&env(&mistral_env(&[("MIO_LESSON_REASONING", "high")]))).unwrap();
    let lesson = resolve_task_profile(&high, "lesson").config.unwrap();
    let request = build_for_profile(mio_gateway::config::profile(&lesson).unwrap(), KEY, &create_task_request(Mode::Lesson, &lesson_payload())).unwrap();
    assert_eq!(request.body["reasoning_effort"], "high");
    let status = gateway_status_v2(&high, None);
    assert_eq!((&status["tasks"]["lesson"]["reasoning"], &status["tasks"]["ask"]["reasoning"]), (&json!("high"), &json!("off")));
    // Ask on Small 4 is untouched: reasoning stays off whatever the lesson level is.
    let ask = resolve_task_profile(&high, "ask").config.unwrap();
    assert_eq!(build_for_profile(mio_gateway::config::profile(&ask).unwrap(), KEY, &create_task_request(Mode::Lesson, &lesson_payload())).unwrap().body["reasoning_effort"], "none");
    // Empty means the reviewed level; a new level is a new configuration for the app.
    let default = load_config(&env(&mistral_env(&[("MIO_LESSON_REASONING", "")]))).unwrap();
    assert_eq!(gateway_status_v2(&default, None)["tasks"]["lesson"]["reasoning"], "medium");
    assert_ne!(configuration_revision(&default), configuration_revision(&high));
    let medium = load_config(&env(&mistral_env(&[("MIO_LESSON_REASONING", "medium")]))).unwrap();
    assert_eq!(configuration_revision(&default), configuration_revision(&medium));
}

#[test]
fn a_level_not_reviewed_for_the_pair_disables_only_lessons() {
    // GPT-6.2 Sol is reviewed at medium only.
    let sol = load_config(&env(&[("MIO_AI_PROVIDER", "mistral"), ("MIO_AI_MODEL", SMALL), ("MISTRAL_API_KEY", KEY), ("OPENAI_API_KEY", KEY),
        ("MIO_GATEWAY_TOKEN", TOKEN), ("MIO_AI_TASK_PROFILES", r#"{"lesson":{"provider":"openai","model":"gpt-6.2-sol"}}"#),
        ("MIO_APPROVED_CANDIDATES", "mistral=mistral-small-2603,openai=gpt-6.2-sol"), ("MIO_LESSON_REASONING", "high")])).unwrap();
    assert_eq!(resolve_task_profile(&sol, "lesson").configuration_error, Some("provider_options_incompatible"));
    assert!(resolve_task_profile(&sol, "ask").configured && resolve_task_profile(&sol, "everyday").configured);
    // A word that is no level at all stops the gateway, like any malformed setting.
    assert!(load_config(&env(&mistral_env(&[("MIO_LESSON_REASONING", "max")]))).is_err());
}

#[test]
fn a_chosen_answer_budget_replaces_the_tasks_own_within_its_range() {
    use mio_gateway::config::answer_limit;
    let config = load_config(&env(&mistral_env(&[("MIO_MAX_OUTPUT_TOKENS_LESSON", "20000"), ("MIO_MAX_OUTPUT_TOKENS_ASK", "")]))).unwrap();
    assert_eq!(config.max_output_tokens.get("lesson"), Some(&20_000));
    assert_eq!(config.max_output_tokens.get("ask"), None, "empty keeps the task's own");
    let large = candidate_profile("mistral", LARGE).unwrap();
    let small = candidate_profile("mistral", SMALL).unwrap();
    assert_eq!(answer_limit(Some(20_000), "lesson", &large, 3_500), 20_000);
    assert_eq!(answer_limit(None, "lesson", &large, 3_500), LESSON_REASONING_MAX_OUTPUT_TOKENS);
    assert_eq!(answer_limit(None, "ask", &small, 1_200), 1_200);
    // A new budget is a new configuration; none chosen leaves the revision as it was.
    assert_ne!(configuration_revision(&config), configuration_revision(&mistral_config()));
    let empty = load_config(&env(&mistral_env(&[("MIO_MAX_OUTPUT_TOKENS_LESSON", "")]))).unwrap();
    assert_eq!(configuration_revision(&empty), configuration_revision(&mistral_config()));
    // Outside the reviewed range the gateway does not start.
    for (key, value) in [("MIO_MAX_OUTPUT_TOKENS_ASK", "299"), ("MIO_MAX_OUTPUT_TOKENS_ASK", "4001"), ("MIO_MAX_OUTPUT_TOKENS_EVERYDAY", "6001"),
        ("MIO_MAX_OUTPUT_TOKENS_LESSON", "1199"), ("MIO_MAX_OUTPUT_TOKENS_LESSON", "32001"), ("MIO_MAX_OUTPUT_TOKENS_LESSON", "många"),
        ("MIO_MAX_OUTPUT_TOKENS_ASK", "0"), ("MIO_MAX_OUTPUT_TOKENS_LESSON", "0")] {
        // 0 is not "no limit" here; the message names the key.
        let error = load_config(&env(&mistral_env(&[(key, value)]))).err().unwrap_or_else(|| panic!("{key}={value}"));
        assert!(error.0.contains(key), "{key}={value}: {}", error.0);
    }
}

#[test]
fn the_thinking_chunk_is_dropped_and_only_the_text_chunk_is_kept_for_lessons() {
    let profile = candidate_profile("mistral", LARGE).unwrap();
    let read = |data: &Value| normalize_provider_response(data, &profile, &|_| None);
    let usage = json!({ "prompt_tokens": 1_000, "completion_tokens": 3_000, "total_tokens": 4_000,
        "completion_tokens_details": { "reasoning_tokens": 2_000 } });
    let answer = read(&chat(json!([thinking(), { "type": "text", "text": "{\"ok\":1}" }]), "stop", usage.clone())).unwrap();
    assert_eq!((answer.finish, answer.text.as_deref()), (Finish::Completed, Some("{\"ok\":1}")));
    assert_eq!(answer.usage.as_ref().unwrap().reasoning_tokens, Some(2_000));
    assert!(!format!("{answer:?}").contains(THOUGHT), "thinking text never leaves the adapter");
    // Thinking that ran out of tokens is a cut-off answer, not an invalid one.
    assert_eq!(read(&chat(json!([thinking()]), "length", usage.clone())).unwrap().finish, Finish::Truncated);
    // Everything else is refused: no text, two texts, empty text, tool or reference chunks.
    for content in [json!([thinking()]), json!([{ "type": "text", "text": "{}" }, { "type": "text", "text": "{}" }]),
        json!([thinking(), { "type": "text", "text": "  " }]), json!([thinking(), { "type": "text" }]),
        json!([thinking(), { "type": "tool_reference", "tool": "x" }, { "type": "text", "text": "{}" }]),
        json!([{ "type": "reference", "reference_ids": [1] }, { "type": "text", "text": "{}" }])] {
        assert_eq!(read(&chat(content.clone(), "stop", usage.clone())).unwrap_err().0, "provider_invalid_response", "{content}");
    }
    let tools = json!({ "choices": [{ "finish_reason": "stop", "message": { "role": "assistant", "content": "{}",
        "tool_calls": [{ "id": "t", "function": { "name": "x", "arguments": "{}" } }] } }] });
    assert_eq!(read(&tools).unwrap_err().0, "provider_invalid_response");
}

#[test]
fn a_thinking_chunk_or_reasoning_tokens_are_refused_for_everyday_and_ask() {
    let profile = candidate_profile("mistral", SMALL).unwrap();
    let read = |data: &Value| normalize_provider_response(data, &profile, &|_| None);
    let chunks = json!([thinking(), { "type": "text", "text": "{}" }]);
    assert_eq!(read(&chat(chunks, "stop", json!({}))).unwrap_err().0, "provider_parameters");
    let reasoned = chat(json!("{}"), "stop", json!({ "prompt_tokens": 10, "completion_tokens": 5,
        "completion_tokens_details": { "reasoning_tokens": 3 } }));
    assert_eq!(read(&reasoned).unwrap_err().0, "provider_parameters");
}

#[test]
fn large_4_can_never_serve_ask_or_everyday() {
    // As the default model it would serve ask and everyday: the gateway refuses to start.
    for extra in [vec![("MIO_AI_MODEL", LARGE)],
        vec![("MIO_AI_TASK_PROFILES", r#"{"ask":{"model":"mistral-large-4-0"}}"#)],
        vec![("MIO_AI_TASK_PROFILES", r#"{"everyday":{"model":"mistral-large-4-0"},"lesson":{"model":"mistral-large-4-0"}}"#)]] {
        let error = load_config(&env(&mistral_env(&extra))).unwrap_err();
        assert!(error.0.contains("provider_options_incompatible"), "{extra:?}");
    }
    // A configuration built without load_config still never resolves it for ask.
    let config = Config { model: LARGE.to_owned(), ..mistral_config() };
    assert_eq!(resolve_task_profile(&config, "ask").configuration_error, Some("provider_options_incompatible"));
    assert_eq!(resolve_task_profile(&config, "everyday").configuration_error, Some("provider_options_incompatible"));
    assert!(resolve_task_profile(&config, "lesson").configured);
    // The recommended setup resolves every task once both pairs are approved.
    let config = mistral_config();
    assert!(["ask", "everyday", "lesson"].iter().all(|task| resolve_task_profile(&config, task).configured));
    // Unapproved, the candidates stay locked.
    let locked = load_config(&env(&mistral_env(&[("MIO_APPROVED_CANDIDATES", "")]))).unwrap();
    assert_eq!(resolve_task_profile(&locked, "lesson").configuration_error, Some("provider_model_incompatible"));
}

#[test]
fn status_names_reasoning_and_schema_dialect_per_task() {
    let status = gateway_status_v2(&mistral_config(), None);
    assert_eq!((&status["tasks"]["ask"]["reasoning"], &status["tasks"]["ask"]["schemaDialect"]), (&json!("off"), &json!("json-schema")));
    assert_eq!(status["tasks"]["everyday"]["reasoning"], "off");
    assert_eq!((&status["tasks"]["lesson"]["reasoning"], &status["tasks"]["lesson"]["model"]), (&json!("medium"), &json!(LARGE)));
    // Large 4 reasons, so the lesson is sent without temperature and the status says so; ask and
    // everyday keep temperature 0 and no note. The backlog is offered (no minute budget).
    assert_eq!(status["tasks"]["lesson"]["temperature"], "provider-default");
    assert!(status["tasks"]["ask"].get("temperature").is_none() && status["tasks"]["everyday"].get("temperature").is_none());
    assert!(status["tasks"]["everyday"]["capabilities"].as_array().unwrap().contains(&json!("analysis-backlog-v1")));
    let groq = load_config(&env(&[("GROQ_API_KEY", "k"), ("MIO_AI_MODEL", "qwen/qwen3.8-27b"), ("MIO_GATEWAY_TOKEN", TOKEN)])).unwrap();
    let status = gateway_status_v2(&groq, None);
    assert_eq!((&status["tasks"]["lesson"]["reasoning"], &status["tasks"]["lesson"]["schemaDialect"]), (&json!("off"), &json!("strict-json-schema")));
    let unconfigured = load_config(&env(&mistral_env(&[("MIO_APPROVED_CANDIDATES", "")]))).unwrap();
    assert_eq!(gateway_status_v2(&unconfigured, None)["tasks"]["lesson"]["schemaDialect"], Value::Null);
}

#[test]
fn usage_adds_reasoning_reported_beside_the_output_and_reads_cached_input() {
    let inside = json!({ "usage": { "prompt_tokens": 100, "completion_tokens": 50, "total_tokens": 150,
        "completion_tokens_details": { "reasoning_tokens": 30 }, "prompt_tokens_details": { "cached_tokens": 40 } } });
    let usage = response_usage(&inside, "chat").unwrap();
    assert_eq!((usage.input_tokens, usage.output_tokens, usage.reasoning_tokens, usage.cached_input_tokens), (Some(100), Some(50), Some(30), Some(40)));
    let beside = json!({ "usage": { "prompt_tokens": 100, "completion_tokens": 20, "total_tokens": 150,
        "completion_tokens_details": { "reasoning_tokens": 30 }, "num_cached_tokens": 10 } });
    let usage = response_usage(&beside, "chat").unwrap();
    assert_eq!((usage.output_tokens, usage.cached_input_tokens), (Some(50), Some(10)));
    assert_eq!(response_usage(&json!({ "choices": [] }), "chat"), None);
}

fn scratch(name: &str) -> std::path::PathBuf {
    let directory = std::env::temp_dir().join(format!("mio-usage-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    std::fs::create_dir_all(&directory).unwrap();
    directory.join("usage.json")
}

/// Lesson (thinking dropped), an invalid lesson answer the provider still billed, and an
/// everyday answer; then the counter in `/v2/status` and in the file, with no text anywhere.
#[tokio::test]
async fn the_usage_counter_counts_every_billed_answer_per_task_and_model() {
    let path = scratch("counter");
    let provider = Provider::new(|index, _| {
        let usage = |prompt: i64, completion: i64, reasoning: i64, cached: i64| json!({ "prompt_tokens": prompt,
            "completion_tokens": completion, "total_tokens": prompt + completion,
            "completion_tokens_details": { "reasoning_tokens": reasoning }, "prompt_tokens_details": { "cached_tokens": cached } });
        let reply = match index {
            0 => chat(json!([thinking(), { "type": "text", "text": lesson_answer().to_string() }]), "stop", usage(1_000, 3_000, 2_000, 100)),
            1 => chat(json!([thinking(), { "type": "text", "text": "{\"nonsense\":true}" }]), "stop", usage(500, 200, 150, 0)),
            _ => chat(json!("{\"answer\":\"Uppgift 7.\"}"), "stop", json!({ "prompt_tokens": 300, "completion_tokens": 20, "total_tokens": 320 })),
        };
        Upstream::json(&reply)
    });
    let mut config = mistral_config();
    config.upstream_timeout_ms = 2_000;
    let gateway = Gateway::new(config, Arc::new(Link(provider.clone()))).unwrap()
        .with_clock(|| NOVEMBER).with_usage_store(Arc::new(FileUsageStore::new(&path)));
    let server = start(gateway).await;
    assert_eq!(server.status_v2().await["usage"], json!({ "month": "2026-11", "currency": "USD", "estimatedCost": 0.0, "entries": [] }));
    let notes = server.post("/v1/lesson-notes", &lesson_payload()).await;
    assert_eq!(notes.status, 200, "{}", notes.body);
    assert!(!notes.body.contains(THOUGHT));
    assert_eq!(notes.header("x-mio-usage-reasoning-tokens"), Some("2000"));
    let sent: Value = serde_json::from_str(&provider.calls.lock().unwrap()[0].body).unwrap();
    assert_eq!((sent["reasoning_effort"].clone(), sent["max_tokens"].clone()), (json!("medium"), json!(12_000)));
    assert_eq!(server.post("/v1/lesson-notes", &lesson_payload()).await.error(), "invalid_lesson_result");
    assert_eq!(server.post("/v1/ask", &json!({ "question": "Vad?", "context": [{ "label": "Anteckning", "text": "Uppgift 7." }] })).await.status, 200);
    let status = server.get("/v2/status", &authorized()).await;
    assert!(!status.body.contains(THOUGHT));
    let usage = status.json()["usage"].clone();
    // Lesson: (1500 - 100) × 0.7 + 100 × 0.07 + 3200 × 2.1 = 7707 per million ≈ 0.0077.
    assert_eq!(usage, json!({ "month": "2026-11", "currency": "USD", "estimatedCost": 0.0078, "entries": [
        { "task": "ask", "provider": "mistral", "model": SMALL, "requests": 1, "inputTokens": 300, "cachedInputTokens": 0,
          "outputTokens": 20, "reasoningTokens": 0, "estimatedCost": 0.0001, "pricesAsOf": "2026-11-20" },
        { "task": "lesson", "provider": "mistral", "model": LARGE, "requests": 2, "inputTokens": 1_500, "cachedInputTokens": 100,
          "outputTokens": 3_200, "reasoningTokens": 2_150, "estimatedCost": 0.0077, "pricesAsOf": "2026-11-20" }] }));
    let file: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(file["schemaVersion"], 1);
    assert_eq!(file["months"]["2026-11"].as_array().unwrap().len(), 2);
    let raw = std::fs::read_to_string(&path).unwrap();
    for private in [THOUGHT, KEY, TOKEN, "Procent", "uppgift"] {
        assert!(!raw.contains(private), "{private}");
    }
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
}

#[tokio::test]
async fn the_chosen_answer_budget_reaches_the_provider() {
    let provider = Provider::new(|_, _| Upstream::json(&chat(json!("{\"answer\":\"Ja.\"}"), "stop", json!({ "prompt_tokens": 5, "completion_tokens": 1 }))));
    let config = load_config(&env(&mistral_env(&[("MIO_MAX_OUTPUT_TOKENS_ASK", "2500")]))).unwrap();
    let server = start(Gateway::new(config, Arc::new(Link(provider.clone()))).unwrap().with_clock(|| NOVEMBER)).await;
    assert_eq!(server.post("/v1/ask", &json!({ "question": "Vad?", "context": [{ "label": "A", "text": "B." }] })).await.status, 200);
    assert_eq!(provider.body(0)["max_tokens"], 2_500);
}

#[tokio::test]
async fn an_unknown_usage_file_is_never_overwritten_and_status_reports_null() {
    let path = scratch("unknown");
    let foreign = r#"{"schemaVersion":2,"months":{"2026-11":[]},"framtid":true}"#;
    std::fs::write(&path, foreign).unwrap();
    let provider = Provider::new(|_, _| Upstream::json(&chat(json!("{\"answer\":\"Ja.\"}"), "stop", json!({ "prompt_tokens": 5, "completion_tokens": 1 }))));
    let gateway = Gateway::new(mistral_config(), Arc::new(Link(provider))).unwrap()
        .with_clock(|| NOVEMBER).with_usage_store(Arc::new(FileUsageStore::new(&path)));
    let server = start(gateway).await;
    assert_eq!(server.post("/v1/ask", &json!({ "question": "Vad?", "context": [{ "label": "A", "text": "B." }] })).await.status, 200);
    assert_eq!(server.status_v2().await["usage"], Value::Null);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), foreign);
    assert_eq!(FileUsageStore::new(&path).load(), Loaded::Unknown);
}

#[test]
fn the_ledger_keeps_this_month_and_the_one_before_and_prices_only_known_models() {
    let mut ledger = Ledger::default();
    let usage = mio_gateway::adapters::Usage { input_tokens: Some(1_000_000), output_tokens: Some(1_000_000), ..Default::default() };
    ledger.record("2026-11", "everyday", "mistral", SMALL, "chat", Some(&usage));
    ledger.record("2026-12", "everyday", "groq", "qwen/qwen3.8-27b", "chat", Some(&usage));
    ledger.record("2026-12", "lesson", "mistral", LARGE, "chat", None);
    assert_eq!(ledger.months.keys().collect::<Vec<_>>(), ["2026-11", "2026-12"]);
    let november = ledger.report("2026-11");
    assert_eq!((november["estimatedCost"].clone(), november["entries"][0]["estimatedCost"].clone()), (json!(0.75), json!(0.75)));
    let december = ledger.report("2026-12");
    // Groq's free tier has no price; an answer without usage counts as a request only.
    assert_eq!((december["entries"][0]["estimatedCost"].clone(), december["entries"][0]["pricesAsOf"].clone()), (Value::Null, Value::Null));
    assert_eq!((december["entries"][1]["requests"].clone(), december["entries"][1]["inputTokens"].clone()), (json!(1), json!(0)));
    assert_eq!(december["estimatedCost"], json!(0.0));
    ledger.record("2027-01", "ask", "mistral", SMALL, "chat", None);
    assert_eq!(ledger.months.keys().collect::<Vec<_>>(), ["2026-12", "2027-01"]);
    assert_eq!(month_of(1_798_934_400_000), "2027-01");
    // Round trip through the file format.
    assert_eq!(Ledger::from_json(&ledger.to_json()), Loaded::Ledger(ledger.clone()));
    assert_eq!(Ledger::from_json(&json!({ "schemaVersion": 1, "months": { "2026-11": [{ "task": "ask", "text": "x" }] } })), Loaded::Unknown);
}

#[test]
fn the_model_list_tells_the_panel_reasoning_tasks_and_prices() {
    let listed: Value = serde_json::from_str(&reviewed_models()).unwrap();
    let find = |group: &str, model: &str| listed[group].as_array().unwrap().iter().find(|entry| entry["model"] == model).cloned().unwrap();
    let large = find("candidates", LARGE);
    assert_eq!((large["reasoning"].clone(), large["tasks"].clone()), (json!("medium"), json!(["lesson"])));
    assert_eq!(large["prices"], json!({ "inputPerMillion": 0.7, "cachedInputPerMillion": 0.07, "outputPerMillion": 2.1, "asOf": "2026-11-20" }));
    let small = find("candidates", SMALL);
    assert_eq!((small["reasoning"].clone(), small["tasks"].clone()), (json!("off"), json!(["ask", "everyday", "lesson"])));
    assert_eq!(small["prices"]["outputPerMillion"], 0.6);
    let groq = find("models", "qwen/qwen3.8-27b");
    assert_eq!((groq["reasoning"].clone(), groq["prices"].clone()), (json!("off"), Value::Null));
    assert!(listed["candidates"].as_array().unwrap().iter().all(|entry| entry["model"] != "mistral-medium-3-5"));
}

#[test]
fn the_trial_tries_large_4_on_lessons_only() {
    let env_file = format!("MISTRAL_API_KEY={KEY}\nMIO_GATEWAY_TOKEN={TOKEN}\nMIO_AI_PROVIDER=mistral\nMIO_AI_MODEL={SMALL}\n\
        MIO_AI_TASK_PROFILES={{\"lesson\":{{\"model\":\"{LARGE}\"}}}}\n");
    let provider = Provider::new(|_, _| Upstream::json(&chat(json!([thinking(), { "type": "text", "text": lesson_answer().to_string() }]), "stop",
        json!({ "prompt_tokens": 900, "completion_tokens": 2_000, "completion_tokens_details": { "reasoning_tokens": 1_200 } }))));
    let answer: Value = serde_json::from_str(&trial(&env_file, "mistral", LARGE, &Link(provider.clone())).unwrap()).unwrap();
    assert_eq!(answer["passed"], true, "{answer}");
    assert_eq!(answer["tasks"].as_array().unwrap().len(), 1);
    assert_eq!((answer["tasks"][0]["task"].clone(), answer["tasks"][0]["reasoningTokens"].clone()), (json!("lesson"), json!(1_200)));
    assert!(!answer.to_string().contains(THOUGHT));
    assert_eq!(provider.count(), 1);
    let sent: Value = serde_json::from_str(&provider.calls.lock().unwrap()[0].body).unwrap();
    assert_eq!((sent["reasoning_effort"].clone(), sent["max_tokens"].clone()), (json!("medium"), json!(12_000)));
}

/// Runs `mode` against a provider that never answers, on paused time, and returns how long the
/// gateway let the call run before it gave up.
async fn deadline(config: &Config, mode: Mode, payload: &Value) -> std::time::Duration {
    let provider = Provider::fixed(Upstream::Hang);
    let started = tokio::time::Instant::now();
    let error = execute_generation(config, mode, payload, &Link(provider.clone()), &mut || Ok(()), &|| NOVEMBER, &Spent::default())
        .await.err().expect("a hanging provider never answers");
    assert_eq!((error.status, error.code), (504, "upstream_timeout"));
    assert_eq!(provider.count(), 1);
    started.elapsed()
}

fn everyday_payload() -> Value {
    json!({ "mode": "everyday", "timeZone": "Europe/Stockholm", "fragments": [{ "id": OLD, "occurredAt": "2026-09-28T08:00:00Z",
        "text": "Jag måste ringa tandläkaren i morgon." }] })
}

/// Contract "Tidsgräns (tillägg efter våg 2)": a lesson on a profile that reasons may take 180 s;
/// everyday, ask and a lesson on a profile that does not reason keep 40 s.
#[tokio::test(start_paused = true)]
async fn a_reasoning_lesson_gets_180_seconds_and_every_other_call_keeps_40() {
    use std::time::Duration;
    let reasoning = mistral_config();
    assert_eq!(reasoning.upstream_timeout_ms, 40_000);
    assert_eq!(deadline(&reasoning, Mode::Lesson, &lesson_payload()).await, Duration::from_millis(LESSON_REASONING_TIMEOUT_MS));
    assert_eq!(LESSON_REASONING_TIMEOUT_MS, 180_000);
    assert_eq!(deadline(&reasoning, Mode::AnalyzeV2, &everyday_payload()).await, Duration::from_secs(40));
    let plain = load_config(&env(&mistral_env(&[("MIO_AI_TASK_PROFILES", r#"{"lesson":{"model":"mistral-small-2603"}}"#)]))).unwrap();
    assert_eq!(resolve_task_profile(&plain, "lesson").config.unwrap().model, SMALL);
    assert_eq!(deadline(&plain, Mode::Lesson, &lesson_payload()).await, Duration::from_secs(40));
    // A lowered limit still lowers every call that does not reason.
    let lowered = Config { upstream_timeout_ms: 2_000, ..reasoning };
    assert_eq!(deadline(&lowered, Mode::AnalyzeV2, &everyday_payload()).await, Duration::from_secs(2));
    assert_eq!(deadline(&lowered, Mode::Lesson, &lesson_payload()).await, Duration::from_secs(180));
}

/// `mio-gateway prova` gives a reasoning lesson the same 180 s and a plain lesson its 40 s.
#[tokio::test(start_paused = true)]
async fn the_trial_gives_a_reasoning_lesson_180_seconds_and_a_plain_one_40() {
    use std::time::Duration;
    for (model, limit) in [(LARGE, Duration::from_secs(180)), (SMALL, Duration::from_secs(40))] {
        let profile = candidate_profile("mistral", model).unwrap();
        let provider = Provider::fixed(Upstream::Hang);
        let started = tokio::time::Instant::now();
        let error = trial_call(profile, KEY, Mode::Lesson, &lesson_payload(), &Link(provider), &|| NOVEMBER, None, None).await.err().unwrap();
        assert_eq!((error.status, error.code, started.elapsed()), (504, "upstream_timeout", limit), "{model}");
    }
}

#[test]
fn a_new_mistral_configuration_loads_and_an_existing_one_keeps_its_provider_and_token() {
    const FRESH: &str = "fresh_gateway_token_0123456789012345678901";
    let written = String::from_utf8(mistral_gateway_env(KEY, None, "8787", FRESH)).unwrap();
    let variables = mio_gateway::tools::environment_file(&written);
    let config = load_config(&|name| variables.get(name).cloned()).unwrap();
    assert_eq!((config.provider.as_str(), config.model.as_str(), config.api_key.as_str()), ("mistral", SMALL, KEY));
    assert_eq!(config.minute_budget("mistral"), None);
    assert!(config.approved_candidates.is_empty(), "approval only after a passed trial");
    assert_eq!(mio_gateway::task_profiles::task_configuration_identifiers(&config, "lesson"), ("mistral".to_owned(), LARGE.to_owned()));
    let approved = format!("{written}MIO_APPROVED_CANDIDATES=mistral={SMALL},mistral={LARGE}\n");
    let answer: Value = serde_json::from_str(&mio_gateway::tools::check_configuration(&approved).unwrap()).unwrap();
    assert_eq!(answer["valid"], true);
    // An existing Groq installation keeps Groq and its token; only the Mistral key is added.
    let groq = format!("GROQ_API_KEY=gsk_old\nMIO_GATEWAY_TOKEN={TOKEN}\nMIO_AI_PROVIDER=groq\nPORT=8787\n");
    assert_eq!(String::from_utf8(mistral_gateway_env(KEY, Some(groq.as_bytes()), "8787", FRESH)).unwrap(), format!("{groq}MISTRAL_API_KEY={KEY}\n"));
}
