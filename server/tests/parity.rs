//! Replays inputs recorded from the JavaScript gateway this crate replaced and requires the
//! same answers: validation, grounding, the exact bytes sent to the model, status, and whole
//! HTTP exchanges with a scripted provider.

mod common;

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};

use common::{Link, Provider, Upstream, start};
use mio_gateway::adapters::{Finish, build_provider_request, normalize_provider_error, normalize_provider_response};
use mio_gateway::analysis::*;
use mio_gateway::config::{Config, load_config};
use mio_gateway::generation::fit_to_minute_budget;
use mio_gateway::model_profiles::provider_profile;
use mio_gateway::server::Gateway;
use mio_gateway::status::{QuotaObservation, configuration_revision, status_from_environment, status_v2_from_environment};
use mio_gateway::tasks::{Mode, create_task_request};
use serde_json::{Value, json};

/// The recording stores long runs of one repeated unit as `{"$repeat": [unit, count]}` and
/// values that occur several times once, in `shared`, referenced as `{"$ref": index}`.
fn expand(value: &Value, shared: &[Value]) -> Value {
    match value {
        Value::Array(items) => items.iter().map(|item| expand(item, shared)).collect(),
        Value::Object(map) if map.len() == 1 && map.contains_key("$repeat") => {
            json!(map["$repeat"][0].as_str().unwrap().repeat(map["$repeat"][1].as_u64().unwrap() as usize))
        }
        Value::Object(map) if map.len() == 1 && map.contains_key("$ref") => {
            expand(&shared[map["$ref"].as_u64().unwrap() as usize], shared)
        }
        Value::Object(map) => Value::Object(map.iter().map(|(key, item)| (key.clone(), expand(item, shared))).collect()),
        other => other.clone(),
    }
}

fn golden() -> Value {
    let recorded: Value = serde_json::from_str(include_str!("golden/node-parity.json")).unwrap();
    let shared = recorded["shared"].as_array().unwrap();
    json!({ "cases": expand(&recorded["cases"], shared), "scenarios": expand(&recorded["scenarios"], shared) })
}

/// Request bodies are several kilobytes of prompt each, so the recording keeps their digest.
fn digest(text: &str) -> Value {
    use sha2::Digest;
    let hash: String = sha2::Sha256::digest(text.as_bytes()).iter().map(|byte| format!("{byte:02x}")).collect();
    json!({ "sha256": hash, "bytes": text.len() })
}

fn outcome<T: Into<Value>, E>(result: Result<T, E>) -> Value {
    result.map_or(Value::Null, Into::into)
}

fn environment(values: &Value) -> impl Fn(&str) -> Option<String> + use<> {
    let values = values.as_object().unwrap().clone();
    move |name| values.get(name).and_then(Value::as_str).map(str::to_owned)
}

fn evaluate(kind: &str, input: &Value) -> Value {
    let ok = |valid: bool| if valid { json!(true) } else { Value::Null };
    match kind {
        "analysis_payload" => ok(validate_analysis_payload(input).is_ok()),
        "lesson_payload" => ok(validate_lesson_payload(input).is_ok()),
        "v2_payload" => ok(validate_analysis_v2_payload(input).is_ok()),
        "ask_payload" => ok(validate_ask_payload(input).is_ok()),
        "analysis_result" => outcome(validate_analysis_result(&input["value"], &input["payload"])),
        "lesson_result" => outcome(validate_lesson_result(&input["value"], &input["payload"])),
        "v2_result" => outcome(validate_analysis_v2_result(&input["value"], &input["payload"])),
        "exact_quote" => json!({ "quote": exact_quote(input["source"].as_str().unwrap(), input["evidence"].as_str().unwrap()) }),
        "provider_request" => {
            let mode = Mode::parse(input["mode"].as_str().unwrap()).unwrap();
            let config = Config { model: common::MODEL.to_owned(), api_key: "fixture-key".to_owned(), ..Config::default() };
            let sized = fit_to_minute_budget(create_task_request(mode, &input["payload"]), mode.task_id(), input["tokensPerMinute"].as_u64());
            match sized.map(|generation| build_provider_request(&config, &generation).unwrap()) {
                Ok(request) => json!({ "url": request.url, "authorization": request.authorization,
                    "maxTokens": request.body["max_tokens"], "body": digest(&request.body.to_string()) }),
                Err(_) => Value::Null,
            }
        }
        "normalize_response" => {
            let profile = provider_profile("groq", common::MODEL, None).unwrap();
            let headers = input["headers"].clone();
            let lookup = |name: &str| headers.get(name).and_then(Value::as_str).map(str::to_owned);
            match normalize_provider_response(&input["data"], &profile, &lookup) {
                Err(error) => json!({ "error": error.0 }),
                Ok(normalized) => json!({ "text": normalized.text, "refusal": normalized.refusal,
                    "finish": match normalized.finish { Finish::Completed => "completed", Finish::Refused => "refused", Finish::Truncated => "truncated" },
                    "requestedModel": normalized.requested_model, "returnedModel": normalized.returned_model,
                    "usage": normalized.usage.map(|usage| { let mut map = serde_json::Map::new();
                        for (name, value) in [("inputTokens", usage.input_tokens), ("outputTokens", usage.output_tokens), ("totalTokens", usage.total_tokens),
                            ("reasoningTokens", usage.reasoning_tokens), ("cachedInputTokens", usage.cached_input_tokens)] {
                            if let Some(value) = value { map.insert(name.to_owned(), json!(value)); }
                        }
                        map }),
                    "provenance": normalized.provenance.map(|provenance| { let mut map = serde_json::Map::new();
                        if let Some(id) = provenance.response_id { map.insert("responseID".to_owned(), json!(id)); }
                        if let Some(id) = provenance.request_id { map.insert("requestID".to_owned(), json!(id)); }
                        map }) }),
            }
        }
        "normalize_error" => {
            let data = input["hasData"].as_bool().unwrap().then(|| &input["data"]);
            let error = normalize_provider_error(input["status"].as_u64().unwrap() as u16, data, input["retryAfter"].as_str(), input["now"].as_i64().unwrap());
            json!({ "category": error.category, "retryAfter": error.retry_after })
        }
        "configuration" => {
            let env = environment(&input["env"]);
            let parsed = load_config(&env);
            let quota = input["quota"].as_object().map(|quota| QuotaObservation { remaining: quota["remaining"].as_i64(),
                reset_at: quota["resetAt"].as_str().map(str::to_owned) });
            json!({ "loads": parsed.is_ok(),
                "config": parsed.as_ref().ok().map(|config| json!({ "provider": config.provider, "apiKey": config.api_key, "model": config.model,
                    "port": config.port, "requestsPerMinute": config.requests_per_minute, "tokensPerMinute": config.tokens_per_minute,
                    "requestsPerDay": config.requests_per_day, "tokensPerDay": config.tokens_per_day, "lessonIntervalSeconds": config.lesson_interval_seconds })),
                "revision": parsed.as_ref().ok().map(configuration_revision),
                "statusV1": status_from_environment(&env, &parsed), "statusV2": status_v2_from_environment(&env, &parsed, quota.as_ref()) })
        }
        other => panic!("unknown case kind {other}"),
    }
}

/// The recorded answer in the shape `evaluate` produces.
fn expected(kind: &str, recorded: &Value) -> Value {
    let value = recorded.get("ok");
    match kind {
        "exact_quote" => json!({ "quote": value.cloned().unwrap_or(Value::Null) }),
        "normalize_response" if value.is_none() => json!({ "error": recorded["error"] }),
        "normalize_error" => json!({ "category": value.unwrap()["category"], "retryAfter": value.unwrap().get("retryAfter").cloned().unwrap_or(Value::Null) }),
        _ => value.cloned().unwrap_or(Value::Null),
    }
}

#[test]
fn pure_functions_answer_as_the_recorded_gateway_did() {
    let golden = golden();
    let mut failures = Vec::new();
    let cases = golden["cases"].as_array().unwrap();
    for (index, case) in cases.iter().enumerate() {
        let kind = case["kind"].as_str().unwrap();
        let (actual, wanted) = (evaluate(kind, &case["input"]), expected(kind, &case["expected"]));
        if actual != wanted {
            let clip = |value: &Value| value.to_string().chars().take(700).collect::<String>();
            failures.push(format!("#{index} {kind}\n  input    {}\n  expected {}\n  actual   {}", clip(&case["input"]), clip(&wanted), clip(&actual)));
        }
    }
    assert!(cases.len() > 2_000);
    assert!(failures.is_empty(), "{} of {} cases differ:\n{}", failures.len(), cases.len(), failures.iter().take(12).cloned().collect::<Vec<_>>().join("\n"));
}

#[tokio::test]
async fn http_exchanges_match_the_recorded_gateway() {
    let golden = golden();
    let mut failures = Vec::new();
    for scenario in golden["scenarios"].as_array().unwrap() {
        let mut values = json!({ "MIO_AI_MODEL": common::MODEL, "GROQ_API_KEY": "fixture-groq", "MIO_GATEWAY_TOKEN": common::TOKEN });
        values.as_object_mut().unwrap().extend(scenario["env"].as_object().unwrap().clone());
        let config = Config { retry_delay_ms: Some(1), upstream_timeout_ms: 5_000, ..load_config(&environment(&values)).unwrap() };
        let time = Arc::new(AtomicI64::new(1_791_720_000_000)); // 2026-10-11T12:00:00Z
        let script: Arc<Mutex<Vec<Value>>> = Arc::default();
        let provider = { let script = script.clone(); Provider::new(move |_, _| {
            let mut script = script.lock().unwrap();
            if script.is_empty() { return Upstream::Fail; }
            let next = script.remove(0);
            if next.get("throw").is_some() { return Upstream::Fail; }
            Upstream::Reply { status: next["status"].as_u64().unwrap() as u16, body: next["body"].as_str().unwrap().as_bytes().to_vec(),
                headers: next["headers"].as_object().unwrap().iter().map(|(name, value)| (name.clone(), value.as_str().unwrap().to_owned())).collect() }
        }) };
        let clock = time.clone();
        let server = start(Gateway::new(config, Arc::new(Link(provider.clone()))).unwrap().with_clock(move || clock.load(Ordering::SeqCst))).await;
        for (index, step) in scenario["steps"].as_array().unwrap().iter().enumerate() {
            time.fetch_add(step["advance"].as_i64().unwrap_or(0), Ordering::SeqCst);
            *script.lock().unwrap() = step["upstream"].as_array().cloned().unwrap_or_default();
            let before = provider.count();
            let request = &step["request"];
            let headers: Vec<(&str, String)> = request["headers"].as_object().unwrap().iter()
                .map(|(name, value)| (name.as_str(), value.as_str().unwrap().to_owned())).collect();
            let reply = server.request(request["method"].as_str().unwrap(), request["path"].as_str().unwrap(), &headers,
                request["body"].as_str().map(str::as_bytes)).await;
            let wanted = &step["expected"];
            let kept: serde_json::Map<String, Value> = wanted["headers"].as_object().unwrap().keys()
                .chain(reply.headers.iter().map(|(name, _)| name).filter(|name| name.starts_with("x-mio-") && *name != "x-mio-request-id" || *name == "retry-after"))
                .map(|name| (name.clone(), json!(reply.header(name)))).collect();
            let calls: Vec<Value> = provider.calls.lock().unwrap()[before..].iter()
                .map(|call| json!({ "url": call.url, "authorization": call.authorization, "body": digest(&call.body) })).collect();
            let actual = json!({ "status": reply.status, "headers": kept, "body": reply.body, "calls": calls, "unusedUpstream": script.lock().unwrap().len() });
            if &actual != wanted {
                let clip = |value: &Value| value.to_string().chars().take(900).collect::<String>();
                failures.push(format!("{} step {index}: {}\n  expected {}\n  actual   {}", scenario["name"], clip(request), clip(wanted), clip(&actual)));
            }
        }
    }
    assert!(failures.is_empty(), "{} exchanges differ:\n{}", failures.len(), failures.join("\n"));
}
