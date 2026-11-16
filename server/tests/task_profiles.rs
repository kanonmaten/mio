mod common;

use common::{MODEL, TOKEN};
use mio_gateway::config::Config;
use mio_gateway::task_profiles::{TASK_IDS, resolve_task_profile};
use serde_json::{Value, json};

fn base() -> Config {
    Config { model: MODEL.to_owned(), api_key: "fixture-groq".to_owned(), gateway_token: TOKEN.to_owned(), requests_per_minute: 6,
        requests_per_day: Some(100), provider_secrets: [("groq".to_owned(), "fixture-groq".to_owned())].into(), ..Config::default() }
}

fn with_profiles(profiles: Value) -> Config {
    Config { task_profiles: Some(profiles), ..base() }
}

#[test]
fn absent_task_overrides_preserve_the_global_configuration_for_every_existing_task() {
    for task in TASK_IDS {
        let result = resolve_task_profile(&base(), task);
        assert!(result.configured && result.configuration_error.is_none());
        let config = result.config.unwrap();
        assert_eq!((config.provider.as_str(), config.model.as_str(), config.api_key.as_str()), ("groq", MODEL, "fixture-groq"));
        assert!(config.provider_secrets.is_empty() && config.task_profiles.is_none());
    }
}

#[test]
fn raw_or_object_profiles_apply_only_to_their_selected_task() {
    let overrides = json!({ "everyday": { "model": "unreviewed-model" } });
    for profiles in [overrides.clone(), json!(overrides.to_string())] {
        let config = with_profiles(profiles);
        assert!(!resolve_task_profile(&config, "everyday").configured);
        assert!(resolve_task_profile(&config, "ask").configured && resolve_task_profile(&config, "lesson").configured);
    }
}

#[test]
fn a_bad_individual_task_disables_only_that_task_and_never_falls_back_to_the_global_model() {
    let config = with_profiles(json!({ "lesson": { "model": "unreviewed-model" } }));
    assert!(resolve_task_profile(&config, "ask").configured && resolve_task_profile(&config, "everyday").configured);
    let lesson = resolve_task_profile(&config, "lesson");
    assert!(!lesson.configured && lesson.config.is_none());
    assert_eq!(lesson.configuration_error, Some("provider_model_incompatible"));
}

#[test]
fn switching_a_task_to_an_unreviewed_provider_fails_closed_and_never_reuses_the_groq_secret() {
    for provider in ["openai", "anthropic", "custom", "unreviewed-provider"] {
        let mut config = with_profiles(json!({ "ask": { "provider": provider, "model": MODEL } }));
        config.provider_secrets.insert(provider.to_owned(), "fixture-other".to_owned());
        let result = resolve_task_profile(&config, "ask");
        assert!(!result.configured && result.config.is_none());
        assert_eq!(result.configuration_error, Some("provider_model_incompatible"));
    }
}

#[test]
fn embedded_secrets_unknown_fields_malformed_overrides_and_unsupported_options_fail_closed() {
    for task_override in [json!(null), json!([]), json!("groq"), json!({ "apiKey": "private-fixture" }), json!({ "headers": {} }),
        json!({ "baseURL": "https://x.invalid/v1" }), json!({ "model": "https://private.invalid/model" }), json!({ "adapterOptions": { "temperature": 1 } })] {
        let config = with_profiles(json!({ "ask": task_override }));
        let ask = resolve_task_profile(&config, "ask");
        assert!(!ask.configured && ask.config.is_none());
        assert!(matches!(ask.configuration_error, Some("task_profile_invalid" | "provider_options_incompatible")), "{task_override}");
        assert!(resolve_task_profile(&config, "everyday").configured && resolve_task_profile(&config, "lesson").configured);
    }
}

#[test]
fn malformed_or_unknown_top_level_profile_keys_do_not_silently_discard_routing_configuration() {
    for profiles in [json!("{broken"), json!("null"), json!("[]"), json!({ "unexpected": { "model": MODEL } })] {
        for task in TASK_IDS {
            let result = resolve_task_profile(&with_profiles(profiles.clone()), task);
            assert!(!result.configured && result.config.is_none());
            assert_eq!(result.configuration_error, Some("task_profiles_invalid"));
        }
    }
}

#[test]
fn unknown_tasks_and_missing_or_unsafe_provider_secrets_produce_fixed_errors_without_secret_output() {
    assert_eq!(resolve_task_profile(&base(), "unimplemented").configuration_error, Some("task_profile_invalid"));
    for api_key in ["", "fixture\r\nheader", TOKEN] {
        let result = resolve_task_profile(&Config { api_key: api_key.to_owned(), ..base() }, "ask");
        assert!(!result.configured && result.config.is_none());
        assert_eq!(result.configuration_error, Some("provider_secret_missing"));
    }
}
