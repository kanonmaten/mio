//! Anthropic (reviewed), Mistral and NVIDIA NIM (candidates) without network: request shape,
//! answers, refusals, cut-off and too-large requests, errors, and the per-provider budget.

mod common;

use common::{TOKEN, env};
use mio_gateway::adapters::{
    ANTHROPIC_VERSION, Finish, build_for_profile, build_provider_request, normalize_provider_error, normalize_provider_response,
};
use mio_gateway::config::{Config, load_config};
use mio_gateway::generation::fit_to_minute_budget;
use mio_gateway::model_profiles::{Incompatible, candidate_profile, provider_profile};
use mio_gateway::status::gateway_status_v2;
use mio_gateway::task_profiles::resolve_task_profile;
use mio_gateway::tasks::{Mode, create_task_request};
use serde_json::{Value, json};

const HAIKU: &str = "claude-haiku-5-5";
const ANTHROPIC_KEY: &str = "fixture-anthropic-key";
const ID: &str = "00000000-0000-0000-0000-000000000001:0";

fn payload() -> Value {
    json!({ "mode": "ask", "question": "Vad ska jag göra till fredag?", "timeZone": "Europe/Stockholm",
        "excerpts": [{ "id": ID, "occurredAt": "2026-09-28T08:00:00Z", "text": "Gör uppgift 7 till fredag." }] })
}

fn anthropic_config() -> Config {
    load_config(&env(&[("MIO_AI_PROVIDER", "anthropic"), ("MIO_AI_MODEL", HAIKU), ("ANTHROPIC_API_KEY", ANTHROPIC_KEY),
        ("GROQ_API_KEY", "must-not-use-groq-key"), ("MIO_GATEWAY_TOKEN", TOKEN)])).unwrap()
}

fn message(stop_reason: &str, content: Value) -> Value {
    json!({ "id": "msg_01", "type": "message", "role": "assistant", "model": HAIKU, "content": content,
        "stop_reason": stop_reason, "usage": { "input_tokens": 120, "output_tokens": 30 } })
}

#[test]
fn anthropic_request_disables_thinking_enforces_the_schema_and_sends_no_temperature() {
    let config = anthropic_config();
    assert_eq!(config.api_key, ANTHROPIC_KEY);
    for mode in [Mode::Ask, Mode::Analyze, Mode::Lesson] {
        let generation = create_task_request(mode, &payload());
        let request = build_provider_request(&config, &generation).unwrap();
        assert_eq!(request.url, "https://api.anthropic.com/v1/messages");
        assert_eq!(request.header("x-api-key"), Some(ANTHROPIC_KEY));
        assert_eq!(request.header("anthropic-version"), Some(ANTHROPIC_VERSION));
        assert_eq!(request.header("Authorization"), None);
        let body = &request.body;
        assert_eq!(body["model"], HAIKU);
        assert_eq!(body["thinking"], json!({ "type": "disabled" }));
        // Disabled thinking is refused above effort high; medium is set explicitly.
        assert_eq!(body["output_config"]["effort"], "medium");
        assert_eq!(body["output_config"]["format"]["type"], "json_schema");
        assert_eq!(body["output_config"]["format"]["schema"], generation.structured_output["schema"]);
        assert_eq!(body["stream"], false);
        for absent in ["temperature", "top_p", "top_k", "tools", "tool_choice", "response_format", "reasoning_effort"] {
            assert!(body.get(absent).is_none(), "{absent}");
        }
        // System text goes apart from the turns, and the first turn is the user's.
        assert!(body["system"].as_str().is_some_and(|system| !system.is_empty()));
        assert!(body["messages"].as_array().unwrap().iter().all(|turn| turn["role"] != "system"));
        assert_eq!(body["messages"][0]["role"], "user");
        let serialized = format!("{request:?} {config:?}");
        assert!(!serialized.contains(ANTHROPIC_KEY) && !body.to_string().contains(ANTHROPIC_KEY));
        assert!(!body.to_string().contains("must-not-use-groq-key"));
    }
}

#[test]
fn anthropic_answers_refusals_cut_offs_thinking_and_tools() {
    let profile = provider_profile("anthropic", HAIKU, None).unwrap();
    let read = |data: &Value| normalize_provider_response(data, &profile, &|name| (name == "request-id").then(|| "req_01".to_owned()));
    let answer = read(&message("end_turn", json!([{ "type": "text", "text": "{\"answer\":\"Uppgift 7.\"}" }]))).unwrap();
    assert_eq!((answer.finish, answer.text.as_deref()), (Finish::Completed, Some("{\"answer\":\"Uppgift 7.\"}")));
    let usage = answer.usage.unwrap();
    assert_eq!((usage.input_tokens, usage.output_tokens, usage.total_tokens), (Some(120), Some(30), Some(150)));
    assert_eq!(answer.provenance.unwrap().request_id.as_deref(), Some("req_01"));
    // A classifier refusal is HTTP 200 with stop_reason refusal, with empty or partial content.
    for content in [json!([]), json!([{ "type": "text", "text": "Jag kan inte" }])] {
        let refused = read(&message("refusal", content)).unwrap();
        assert_eq!((refused.finish, refused.refusal, refused.text), (Finish::Refused, true, None));
    }
    assert_eq!(read(&message("max_tokens", json!([{ "type": "text", "text": "{\"answ" }]))).unwrap().finish, Finish::Truncated);
    // Thinking that comes back anyway breaks the reasoning-off contract.
    let thinking = message("end_turn", json!([{ "type": "thinking", "thinking": "", "signature": "x" }, { "type": "text", "text": "{}" }]));
    assert_eq!(read(&thinking).unwrap_err().0, "provider_parameters");
    for bad in [
        message("tool_use", json!([{ "type": "tool_use", "id": "t", "name": "x", "input": {} }])),
        message("pause_turn", json!([{ "type": "text", "text": "{}" }])),
        message("end_turn", json!([{ "type": "text", "text": "{}" }, { "type": "text", "text": "{}" }])),
        message("end_turn", json!([{ "type": "text", "text": "  " }])),
        json!({ "type": "error", "error": { "type": "overloaded_error" } }),
    ] {
        assert_eq!(read(&bad).unwrap_err().0, "provider_invalid_response", "{bad}");
    }
}

#[test]
fn anthropic_errors_map_to_mios_categories() {
    let error = |kind: &str| json!({ "type": "error", "error": { "type": kind, "message": "provider text never leaves" } });
    let category = |status: u16, kind: &str| normalize_provider_error(status, Some(&error(kind)), None, 0).category;
    assert_eq!(category(401, "authentication_error"), "provider_authentication");
    assert_eq!(category(403, "permission_error"), "provider_account");
    assert_eq!(category(404, "not_found_error"), "provider_model_unavailable");
    assert_eq!(category(429, "rate_limit_error"), "provider_quota");
    // Too large is never a reason to wait: the app shrinks or splits the work.
    assert_eq!(category(413, "request_too_large"), "provider_request_too_large");
    assert_eq!(category(400, "invalid_request_error"), "provider_parameters");
    // Overloaded is temporary infrastructure, eligible for the one identical retry.
    assert_eq!(category(529, "overloaded_error"), "provider_infrastructure");
    assert_eq!(normalize_provider_error(429, Some(&error("rate_limit_error")), Some("12"), 0).retry_after, Some(12));
}

#[test]
fn only_haiku_55_is_reviewed_at_anthropic() {
    for model in ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5", "claude-haiku-5-5-20260101", "claude-fable-5-2"] {
        assert_eq!(provider_profile("anthropic", model, None), Err(Incompatible::Model), "{model}");
    }
    assert!(!provider_profile("anthropic", HAIKU, None).unwrap().temperature);
    assert!(provider_profile("groq", "qwen/qwen3.8-27b", None).unwrap().temperature);
}

#[test]
fn candidates_are_refused_until_a_live_test_is_approved() {
    for (provider, model) in [("mistral", "mistral-small-2603"), ("mistral", "mistral-medium-3-5"), ("nvidia", "qwen/qwen3.8-27b")] {
        assert_eq!(provider_profile(provider, model, None), Err(Incompatible::Model), "{provider} {model}");
        let candidate = candidate_profile(provider, model).unwrap();
        assert_eq!(candidate.contract_review.status, "candidate");
        let config = load_config(&env(&[("MIO_AI_PROVIDER", provider), ("MIO_AI_MODEL", model),
            ("MISTRAL_API_KEY", "fixture-mistral"), ("NVIDIA_API_KEY", "fixture-nvidia"), ("MIO_GATEWAY_TOKEN", TOKEN)])).unwrap();
        assert_eq!(resolve_task_profile(&config, "ask").configuration_error, Some("provider_model_incompatible"));
    }
    assert!(candidate_profile("mistral", "mistral-large-4-0").is_none(), "Large 4 cannot turn reasoning off");
}

#[test]
fn mistral_candidate_turns_reasoning_off_and_rejects_thinking_chunks() {
    let profile = candidate_profile("mistral", "mistral-small-2603").unwrap();
    let request = build_for_profile(profile.clone(), "fixture-mistral", &create_task_request(Mode::Ask, &payload())).unwrap();
    assert_eq!(request.url, "https://api.mistral.ai/v1/chat/completions");
    assert_eq!(request.header("Authorization"), Some("Bearer fixture-mistral"));
    assert_eq!((request.body["reasoning_effort"].clone(), request.body["temperature"].clone()), (json!("none"), json!(0)));
    assert_eq!(request.body["response_format"]["json_schema"]["strict"], true);
    let chat = |content: Value, finish: &str| json!({ "choices": [{ "finish_reason": finish, "message": { "role": "assistant", "content": content } }] });
    let read = |data: &Value| normalize_provider_response(data, &profile, &|_| None);
    assert_eq!(read(&chat(json!("{\"answer\":\"x\"}"), "stop")).unwrap().finish, Finish::Completed);
    assert_eq!(read(&chat(json!("{\"ans"), "model_length")).unwrap().finish, Finish::Truncated);
    let chunks = json!([{ "type": "thinking", "thinking": [{ "type": "text", "text": "…" }] }, { "type": "text", "text": "{}" }]);
    assert_eq!(read(&chat(chunks, "stop")).unwrap_err().0, "provider_parameters");
    assert_eq!(read(&chat(json!([{ "type": "text", "text": "{}" }]), "stop")).unwrap_err().0, "provider_invalid_response");
}

#[test]
fn nvidia_candidate_turns_thinking_off_through_the_chat_template() {
    let profile = candidate_profile("nvidia", "qwen/qwen3.8-27b").unwrap();
    let request = build_for_profile(profile, "fixture-nvidia", &create_task_request(Mode::Analyze, &payload())).unwrap();
    assert_eq!(request.url, "https://integrate.api.nvidia.com/v1/chat/completions");
    assert_eq!(request.body["chat_template_kwargs"], json!({ "enable_thinking": false }));
    assert!(request.body.get("reasoning_effort").is_none());
    assert_eq!(request.body["temperature"], 0);
}

#[test]
fn the_minute_budget_belongs_to_each_provider() {
    let config = load_config(&env(&[("MIO_AI_PROVIDER", "anthropic"), ("MIO_AI_MODEL", HAIKU), ("ANTHROPIC_API_KEY", ANTHROPIC_KEY),
        ("MIO_GATEWAY_TOKEN", TOKEN), ("MIO_TOKENS_PER_MINUTE_ANTHROPIC", "50000")])).unwrap();
    // Groq keeps its free-tier default; Anthropic gets only what is set for it.
    assert_eq!((config.minute_budget("groq"), config.minute_budget("anthropic"), config.minute_budget("mistral")), (Some(8_000), Some(50_000), None));
    let generation = create_task_request(Mode::Lesson, &payload());
    let wanted = generation.max_output_tokens;
    assert_eq!(fit_to_minute_budget(generation.clone(), "lesson", config.minute_budget("anthropic")).unwrap().max_output_tokens, wanted);
    assert_eq!(fit_to_minute_budget(generation, "lesson", config.minute_budget("mistral")).unwrap().max_output_tokens, wanted);
    let refused = load_config(&env(&[("MIO_GATEWAY_TOKEN", TOKEN), ("MIO_TOKENS_PER_MINUTE_ANTHROPIC", "10")]));
    assert!(refused.is_err(), "a budget below 2 000 is refused like Groq's");
}

#[test]
fn status_says_when_temperature_is_left_to_the_provider() {
    let status = gateway_status_v2(&anthropic_config(), None);
    for task in ["ask", "everyday", "lesson"] {
        assert_eq!(status["tasks"][task]["temperature"], "provider-default", "{task}");
        assert_eq!(status["tasks"][task]["provider"], "anthropic");
    }
    let groq = load_config(&env(&[("GROQ_API_KEY", "k"), ("MIO_AI_MODEL", "qwen/qwen3.8-27b"), ("MIO_GATEWAY_TOKEN", TOKEN)])).unwrap();
    assert!(gateway_status_v2(&groq, None)["tasks"]["ask"].get("temperature").is_none(), "Groq's status is unchanged");
}

/// The whole path through the HTTP server: sizing, headers, reading the Messages answer and
/// validating it, then a refusal, which reaches the app as a content-dependent failure.
#[tokio::test]
async fn an_ask_through_the_gateway_with_anthropic() {
    use common::{Provider, Upstream, serve};
    let mut config = anthropic_config();
    config.upstream_timeout_ms = 2_000;
    let provider = Provider::new(|index, _| {
        let reply = if index == 0 {
            message("end_turn", json!([{ "type": "text", "text": "{\"answer\":\"Procent betyder hundradelar.\"}" }]))
        } else {
            message("refusal", json!([]))
        };
        Upstream::new(200, &[("content-type", "application/json"), ("request-id", "req_ok")], reply.to_string())
    });
    let server = serve(config, &provider).await;
    let ask = json!({ "question": "Vad betyder procent?", "context": [{ "label": "Anteckning", "text": "Vi övar procent." }] });
    let response = server.post("/v1/ask", &ask).await;
    assert_eq!(response.status, 200, "{}", response.body);
    assert_eq!(response.json(), json!({ "answer": "Procent betyder hundradelar." }));
    {
        let calls = provider.calls.lock().unwrap();
        assert_eq!(calls[0].url, "https://api.anthropic.com/v1/messages");
        assert_eq!(calls[0].authorization, ANTHROPIC_KEY);
        assert!(calls[0].headers.contains(&("anthropic-version", ANTHROPIC_VERSION.to_owned())));
        let body: Value = serde_json::from_str(&calls[0].body).unwrap();
        assert!(body.get("temperature").is_none() && body["thinking"]["type"] == "disabled");
        assert!(!calls[0].body.contains(TOKEN));
    }
    let refused = server.post("/v1/ask", &ask).await;
    assert_eq!((refused.status, refused.error()), (502, "provider_refusal".to_owned()));
    // A refusal is not retried: the same text at temperature 0 would be refused again.
    assert_eq!(provider.count(), 2);
}
