mod common;

use common::MODEL;
use mio_gateway::adapters::*;
use mio_gateway::config::Config;
use mio_gateway::model_profiles::{Incompatible, provider_profile};
use mio_gateway::tasks::{Mode, create_task_request, validate_task_result};
use serde_json::{Value, json};

fn generic() -> Generation {
    Generation {
        messages: vec![Message { role: "system".to_owned(), content: "Extract one label.".to_owned() },
            Message { role: "user".to_owned(), content: "Synthetic example.".to_owned() }],
        structured_output: json!({ "type": "json_schema", "name": "label", "strict": true,
            "schema": { "type": "object", "properties": { "label": { "type": "string" } }, "required": ["label"], "additionalProperties": false } }),
        max_output_tokens: 321, policy: Policy::default(), prompt_version: "",
    }
}

fn config(provider: &str, model: &str) -> Config {
    Config { provider: provider.to_owned(), model: model.to_owned(), api_key: "synthetic-secret".to_owned(),
        adapter_options: Some(json!({})), ..Config::default() }
}

fn response() -> Value {
    json!({ "id": "completion_123", "model": "returned-model-123",
        "choices": [{ "index": 0, "finish_reason": "stop", "message": { "role": "assistant", "content": "{\"label\":\"a\"}" } }],
        "usage": { "prompt_tokens": 10, "completion_tokens": 3, "total_tokens": 13, "completion_tokens_details": { "reasoning_tokens": 0 } } })
}

fn normalize(data: &Value, request_id: Option<&str>) -> Result<Normalized, ResponseError> {
    let profile = provider_profile("groq", MODEL, None).unwrap();
    normalize_provider_response(data, &profile, &|name| request_id.filter(|_| name == "x-request-id").map(str::to_owned))
}

#[test]
fn exact_catalog_rejects_invented_snapshots_and_other_providers_without_a_substitute_model() {
    for (provider, model) in [("groq", "qwen/qwen3.8-27b-2099"), ("groq", "qwen/qwen3.8"), ("groq", "QWEN/QWEN3.8-27B"),
        ("openai", "gpt-5.1-2025-11-13"), ("anthropic", "claude-opus-4-5-20251101"), ("mistral", "mistral-small-latest"),
        ("deepseek", "deepseek-flash"), ("__proto__", MODEL), ("constructor", MODEL)] {
        assert!(provider_profile(provider, model, None).is_err());
        let generation = create_task_request(Mode::Ask, &json!({ "question": "Synthetic" }));
        assert!(build_provider_request(&config(provider, model), &generation).is_err());
    }
}

#[test]
fn reviewed_groq_profile_exposes_policy_documentation_sources_and_separate_live_verification() {
    let profile = provider_profile("groq", MODEL, Some(&json!({}))).unwrap();
    assert_eq!(profile.requested_model, MODEL);
    assert_eq!(profile.wire, "chat");
    assert_eq!(profile.capabilities, ["reasoning-off", "temperature-zero", "strict-json"]);
    assert!(!profile.contract_review.live_tested);
    assert!(!profile.contract_review.sources.is_empty());
    assert!(profile.contract_review.sources.iter().all(|url| url.starts_with("https://console.groq.com/")));
}

#[test]
fn task_definition_owns_prompt_schema_budget_and_validates_domain_independently() {
    let ask = create_task_request(Mode::Ask, &json!({ "question": "Syntetisk fråga", "context": [] }));
    assert_eq!(ask.max_output_tokens, 1_200);
    assert_eq!(ask.policy, Policy { reasoning: "off".to_owned(), temperature: 0.0, tools: "none".to_owned() });
    assert_eq!(ask.messages[1].content, "{\"question\":\"Syntetisk fråga\",\"context\":[]}");
    let lesson = create_task_request(Mode::Lesson, &json!({ "fragments": [] }));
    assert_eq!(lesson.max_output_tokens, 3_000);
    assert_eq!(lesson.structured_output["schema"]["properties"]["candidates"]["items"]["properties"]["kind"]["enum"], json!(["plan", "task"]));
    assert_eq!(create_task_request(Mode::AnalyzeV2, &json!({})).prompt_version, "2026-10-13.2");
    assert_eq!(validate_task_result(Mode::Ask, "{\"answer\":\"Syntetiskt svar\"}", &json!({})), Ok(json!({ "answer": "Syntetiskt svar" })));
    for (mode, text, error) in [(Mode::Ask, "{\"answer\":\"x\",\"action\":\"create\"}", "invalid_upstream_answer"),
        (Mode::Analyze, "{}", "invalid_analysis_result"), (Mode::Lesson, "{}", "invalid_lesson_result"),
        (Mode::Lesson, "invalid JSON private text", "invalid_lesson_result")] {
        assert_eq!(validate_task_result(mode, text, &json!({})), Err(error));
    }
    assert_eq!(Mode::parse("unknown"), None);
}

#[test]
fn groq_adapter_preserves_explicit_native_generation_contract_without_task_information() {
    let request = build_provider_request(&config("groq", MODEL), &generic()).unwrap();
    assert_eq!(request.url, "https://api.groq.com/openai/v1/chat/completions");
    assert_eq!(request.profile.requested_model, MODEL);
    assert!(!request.body.to_string().contains("mio_"));
    assert_eq!(request.body["model"], MODEL);
    assert_eq!(request.body["temperature"], 0);
    assert_eq!(request.body["max_tokens"], 321);
    assert_eq!(request.body["response_format"]["type"], "json_schema");
    assert_eq!(request.body["response_format"]["json_schema"]["strict"], true);
    assert_eq!(request.body["response_format"]["json_schema"]["schema"]["additionalProperties"], false);
    assert_eq!(request.body["stream"], false);
    assert_eq!(request.body["reasoning_effort"], "none");
    assert!(request.body.get("tools").is_none());
    assert_eq!(request.authorization, "Bearer synthetic-secret");
    assert_eq!(request.body["messages"], json!([{ "role": "system", "content": "Extract one label." }, { "role": "user", "content": "Synthetic example." }]));
    assert_eq!(normalize(&response(), None).unwrap().text.as_deref(), Some("{\"label\":\"a\"}"));
}

#[test]
fn adapter_cannot_weaken_policy_allow_tools_or_silently_discard_schema_keywords() {
    let build = |change: &dyn Fn(&mut Generation)| {
        let mut generation = generic();
        change(&mut generation);
        build_provider_request(&config("groq", MODEL), &generation)
    };
    assert!(build(&|_| {}).is_ok());
    assert!(build(&|generation| generation.policy.reasoning = "hidden".to_owned()).is_err());
    assert!(build(&|generation| generation.policy.temperature = 1.0).is_err());
    assert!(build(&|generation| generation.policy.tools = "auto".to_owned()).is_err());
    assert!(build(&|generation| generation.structured_output["strict"] = json!(false)).is_err());
    assert!(build(&|generation| generation.structured_output["schema"]["properties"]["label"]["pattern"] = json!("^a$")).is_err());
    assert!(build(&|generation| generation.structured_output["schema"]["additionalProperties"] = json!(true)).is_err());
    assert!(build(&|generation| generation.structured_output["schema"]["required"] = json!([])).is_err());
    assert!(build(&|generation| generation.structured_output["schema"]["properties"]["label"]["enum"] = json!([{}])).is_err());
    assert!(build(&|generation| generation.max_output_tokens = 0).is_err());
    assert!(build(&|generation| generation.messages.remove(1).content.clear()).is_err());
    assert!(build(&|generation| generation.messages.push(Message { role: "system".to_owned(), content: "Late.".to_owned() })).is_err());
    assert!(build(&|generation| generation.messages[1].role = "tool".to_owned()).is_err());
}

#[test]
fn groq_accepts_no_routing_or_retention_options_and_any_option_is_a_configuration_error() {
    for options in [json!({ "apiKey": "private" }), json!({ "headers": { "Secret": "x" } }), json!({ "allowFallbacks": true }), json!([]), json!("x")] {
        assert_eq!(provider_profile("groq", MODEL, Some(&options)), Err(Incompatible::Options));
    }
    assert!(provider_profile("groq", MODEL, Some(&json!({}))).is_ok());
}

#[test]
fn normalization_retains_requested_and_returned_identity_numeric_usage_and_bounded_provenance_only() {
    let result = normalize(&response(), Some("req_abc")).unwrap();
    assert_eq!(result, Normalized { text: Some("{\"label\":\"a\"}".to_owned()), finish: Finish::Completed, refusal: false,
        requested_model: MODEL.to_owned(), returned_model: Some("returned-model-123".to_owned()),
        usage: Some(Usage { input_tokens: Some(10), output_tokens: Some(3), total_tokens: Some(13), reasoning_tokens: Some(0), cached_input_tokens: None }),
        provenance: Some(Provenance { response_id: Some("completion_123".to_owned()), request_id: Some("req_abc".to_owned()) }) });
    let mut unsafe_data = response();
    unsafe_data["model"] = json!(format!("private prompt\n{}", "x".repeat(180)));
    unsafe_data["id"] = json!("url?secret=1");
    unsafe_data["usage"] = json!({ "prompt_tokens": -1, "completion_tokens": "3", "total_tokens": 1e300 });
    let result = normalize(&unsafe_data, Some("private?token=1")).unwrap();
    assert_eq!((result.returned_model, result.usage, result.provenance), (None, None, None));
}

#[test]
fn chat_wire_distinguishes_refusal_and_truncation_and_rejects_tools_thinking_and_malformed_success() {
    let patched = |pointer: &str, value: Value| {
        let mut data = response();
        let (parent, key) = pointer.rsplit_once('/').unwrap();
        data.pointer_mut(parent).unwrap()[key] = value;
        data
    };
    for data in [patched("/choices/0/message/refusal", json!("private refusal text")), patched("/choices/0/finish_reason", json!("content_filter"))] {
        let result = normalize(&data, None).unwrap();
        assert_eq!((result.finish, result.refusal, &result.text), (Finish::Refused, true, &None));
        assert!(!format!("{result:?}").contains("private refusal"));
    }
    assert_eq!(normalize(&patched("/choices/0/finish_reason", json!("length")), None).unwrap().finish, Finish::Truncated);
    for invalid in [patched("/choices/0/message/reasoning_content", json!("private thought")), patched("/choices/0/message/reasoning", json!("private thought")),
        patched("/choices/0/message/tool_calls", json!([{ "type": "function" }])), patched("/choices/0/message/function_call", json!({ "name": "private_tool" })),
        json!({}), json!({ "choices": [] })] {
        assert!(normalize(&invalid, None).is_err(), "{invalid}");
    }
    assert_eq!(normalize(&patched("/choices/0/message/reasoning_content", Value::Null), None).unwrap().text.as_deref(), Some("{\"label\":\"a\"}"));
    let positive = patched("/usage", json!({ "completion_tokens_details": { "reasoning_tokens": 1 } }));
    assert_eq!(normalize(&positive, None), Err(ResponseError("provider_parameters")));
}

#[test]
fn safe_error_normalization_preserves_distinct_fixed_categories_without_provider_text() {
    for (status, data, category) in [(401, json!({}), "provider_authentication"), (403, json!({}), "provider_account"),
        (402, json!({}), "provider_account"), (404, json!({}), "provider_model_unavailable"), (400, json!({}), "provider_parameters"),
        (422, json!({}), "provider_parameters"), (429, json!({}), "provider_quota"), (529, json!({}), "provider_infrastructure"),
        (413, json!({ "error": { "code": "rate_limit_exceeded" } }), "provider_request_too_large"),
        (400, json!({ "error": { "code": "model_not_found" } }), "provider_model_unavailable"),
        (400, json!({ "error": { "code": "invalid_api_key" } }), "provider_authentication"),
        (400, json!({ "error": { "code": "rate_limit_exceeded" } }), "provider_quota")] {
        let mut data = data;
        data["private"] = json!("secret transcript");
        assert_eq!(normalize_provider_error(status, Some(&data), None, 0), ProviderError { category, retry_after: None });
    }
}

#[test]
fn retry_after_accepts_bounded_seconds_and_http_dates_and_drops_malformed_values() {
    let now = 1_790_935_200_000; // 2026-10-02T10:00:00Z
    for (value, expected) in [("123", Some(123)), ("99999999", Some(3_600)), ("Fri, 02 Oct 2026 10:02:00 GMT", Some(120)),
        ("Fri, 02 Oct 2026 09:59:00 GMT", Some(0)), ("-1", None), ("private-token", None), ("1.5", Some(2)), ("1.5.2", None)] {
        assert_eq!(normalize_provider_error(429, None, Some(value), now), ProviderError { category: "provider_quota", retry_after: expected }, "{value}");
    }
}

#[test]
fn operational_metadata_drops_full_urls_and_common_credential_prefixes() {
    for value in ["https://private.example/path", "http://private.example/path", "sk-private-token", "sk_proj_private", "gsk_private"] {
        let mut data = response();
        data["id"] = json!(value);
        data["model"] = json!(value);
        let result = normalize(&data, Some(value)).unwrap();
        assert_eq!((&result.returned_model, &result.provenance), (&None, &None));
        assert!(!format!("{result:?}").contains(value));
    }
}

#[test]
fn models_cannot_be_urls_or_accidentally_copied_credentials() {
    for model in ["https://private.example/model", "sk-private-token", "gsk_private", "nvapi-secret"] {
        assert_eq!(build_provider_request(&config("groq", model), &generic()), Err(Incompatible::Model));
    }
}
