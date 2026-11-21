//! Lesson notes v2 (contract "Lektionsanteckningar version 2" in docs/DATAMODELL.md): exam
//! hints, speaker roles and a subject suggestion on `/v2/lesson-notes`, beside an unchanged v1.

mod common;

use std::time::Duration;

use common::{Link, MODEL, Provider, TOKEN, Upstream, env, serve, with};
use mio_gateway::adapters::build_provider_request;
use mio_gateway::analysis::{validate_lesson_payload, validate_lesson_v2_payload, validate_lesson_v2_result};
use mio_gateway::config::{Config, load_config};
use mio_gateway::generation::{Spent, execute_generation};
use mio_gateway::prompts::{LESSON_SYSTEM, LESSON_V2_PROMPT_VERSION, lesson_v2_system};
use mio_gateway::tasks::{Mode, create_task_request};
use serde_json::{Value, json};

const FIRST: &str = "00000000-0000-0000-0000-000000000001:0";
const SECOND: &str = "00000000-0000-0000-0000-000000000001:1";
const TEACHER: &str = "Det här kommer på provet: fotosyntesen omvandlar ljus till socker. Kom ihåg formeln.";
const STUDENT: &str = "Måste vi kunna allt om klorofyll?";

fn payload() -> Value {
    json!({ "mode": "lesson", "timeZone": "Europe/Stockholm", "fragments": [
        { "id": FIRST, "occurredAt": "2026-11-20T08:00:00Z", "text": TEACHER, "speakerRole": "teacher" },
        { "id": SECOND, "occurredAt": "2026-11-20T08:01:00Z", "text": STUDENT, "speakerRole": "student" }] })
}

fn hint(text: &str, ids: &[&str], evidence: &str) -> Value {
    json!({ "text": text, "sourceIDs": ids, "evidence": evidence })
}

fn answer(hints: Vec<Value>, subject: Value) -> Value {
    json!({ "examHints": hints, "subject": subject, "candidates": [],
        "sections": [{ "heading": "Fotosyntes", "body": "Fotosyntesen omvandlar ljus till socker.",
            "sourceIDs": [FIRST], "evidence": "fotosyntesen omvandlar ljus till socker" }],
        "uncertainties": [] })
}

#[test]
fn speaker_roles_are_optional_and_only_teacher_or_student() {
    assert!(validate_lesson_v2_payload(&payload()).is_ok());
    let mut unknown = payload();
    unknown["fragments"][1].as_object_mut().unwrap().shift_remove("speakerRole");
    assert!(validate_lesson_v2_payload(&unknown).is_ok(), "an unknown speaker has no role");
    for role in [json!("Anna"), json!(null), json!(1), json!("Teacher")] {
        let mut wrong = payload();
        wrong["fragments"][0]["speakerRole"] = role;
        assert!(validate_lesson_v2_payload(&wrong).is_err());
    }
    let mut extra = payload();
    extra["fragments"][0]["speaker"] = json!(1);
    assert!(validate_lesson_v2_payload(&extra).is_err(), "no other fields, and no speaker names");
    // v1 is unchanged: it refuses the new field.
    assert!(validate_lesson_payload(&payload()).is_err());
    assert!(validate_lesson_v2_payload(&with(&payload(), json!({ "mode": "everyday" }))).is_err());
    let mut long = unknown.clone();
    long["fragments"][0]["text"] = json!("å".repeat(1_751));
    assert!(validate_lesson_v2_payload(&long).is_err(), "the 3,500-byte source limit applies");
}

#[test]
fn the_v2_request_has_its_own_schema_prompt_and_version_and_sends_the_roles() {
    let generation = create_task_request(Mode::LessonV2, &payload());
    assert_eq!(generation.prompt_version, LESSON_V2_PROMPT_VERSION);
    assert_ne!(LESSON_V2_PROMPT_VERSION, mio_gateway::prompts::PROMPT_VERSION);
    assert!(generation.messages[0].content.starts_with(LESSON_SYSTEM) && generation.messages[0].content == lesson_v2_system());
    for phrase in ["det här kommer på provet", "kom ihåg", "viktigt", "Hellre för få provtips än gissningar", "speakerRole"] {
        assert!(generation.messages[0].content.contains(phrase), "{phrase}");
    }
    assert_eq!(generation.messages[1].content, payload().to_string(), "the roles reach the model as the app sent them");
    let config = Config { model: MODEL.to_owned(), api_key: "fixture-key".to_owned(), ..Config::default() };
    let request = build_provider_request(&config, &generation).unwrap();
    let format = &request.body["response_format"]["json_schema"];
    assert_eq!(format["name"], "mio_lesson_notes_v2");
    let keys: Vec<&String> = format["schema"]["properties"].as_object().unwrap().keys().collect();
    assert_eq!(keys, ["examHints", "subject", "candidates", "sections", "uncertainties"]);
    assert_eq!(format["schema"]["properties"]["subject"]["type"], json!(["string", "null"]));
    // v1 keeps its schema name.
    let v1 = build_provider_request(&config, &create_task_request(Mode::Lesson, &with(&payload(), json!({})))).unwrap();
    assert_eq!(v1.body["response_format"]["json_schema"]["name"], "mio_lesson_notes_v1");
}

#[test]
fn exam_hints_are_grounded_repaired_or_dropped_one_by_one() {
    let hints = vec![
        hint("Fotosyntesen omvandlar ljus till socker.", &[FIRST], "Det här kommer på provet"),
        // A repaired quote: case and punctuation differ, and the source the model forgot is added.
        hint("Kunna formeln.", &[], "kom ihåg formeln"),
        hint("Påhittat", &[FIRST], "det här står inte i källan"),
        hint("", &[FIRST], "Kom ihåg formeln."),
        hint(&"x".repeat(301), &[FIRST], "Kom ihåg formeln."),
        json!({ "text": "Extra fält", "sourceIDs": [FIRST], "evidence": "Kom ihåg formeln.", "extra": 1 }),
        json!("inte ett objekt"),
    ];
    let result = validate_lesson_v2_result(&answer(hints, json!("Biologi")), &payload()).unwrap();
    let kept = result["examHints"].as_array().unwrap();
    assert_eq!(kept.len(), 2, "{kept:?}");
    assert_eq!(kept[0], hint("Fotosyntesen omvandlar ljus till socker.", &[FIRST], "Det här kommer på provet"));
    assert_eq!(kept[1], hint("Kunna formeln.", &[FIRST], "Kom ihåg formeln"));
    assert_eq!(result["subject"], "Biologi");
    assert_eq!(result["sections"].as_array().unwrap().len(), 1);
    let keys: Vec<&String> = result.as_object().unwrap().keys().collect();
    assert_eq!(keys, ["examHints", "subject", "candidates", "sections", "uncertainties"], "exam hints come first");
    // 300 characters are allowed even when they are more than 300 bytes.
    let long = validate_lesson_v2_result(&answer(vec![hint(&"å".repeat(300), &[FIRST], "Kom ihåg formeln.")], json!(null)), &payload()).unwrap();
    assert_eq!(long["examHints"].as_array().unwrap().len(), 1);
}

#[test]
fn at_most_eight_hints_and_four_sources_each() {
    let many: Vec<Value> = (0..12).map(|index| hint(&format!("Tips {index}"), &[FIRST], "Kom ihåg formeln.")).collect();
    let result = validate_lesson_v2_result(&answer(many, json!(null)), &payload()).unwrap();
    assert_eq!(result["examHints"].as_array().unwrap().len(), 8);
    // Five listed sources: only those holding the quote stay.
    let fragments: Vec<Value> = (0..5).map(|index| json!({ "id": format!("00000000-0000-0000-0000-000000000001:{index}"),
        "occurredAt": "2026-11-20T08:00:00Z", "text": if index == 3 { TEACHER } else { "Ett annat stycke." } })).collect();
    let five = json!({ "mode": "lesson", "timeZone": "Europe/Stockholm", "fragments": fragments });
    let ids: Vec<String> = (0..5).map(|index| format!("00000000-0000-0000-0000-000000000001:{index}")).collect();
    let listed: Vec<&str> = ids.iter().map(String::as_str).collect();
    let mut notes = answer(vec![hint("Formeln", &listed, "Kom ihåg formeln.")], json!(null));
    notes["sections"][0]["sourceIDs"] = json!([ids[3]]);
    let result = validate_lesson_v2_result(&notes, &five).unwrap();
    assert_eq!(result["examHints"][0]["sourceIDs"], json!([ids[3]]));
}

#[test]
fn the_subject_is_a_short_suggestion_or_null() {
    for (subject, expected) in [(json!("Biologi"), json!("Biologi")), (json!("  Matematik "), json!("Matematik")),
        (json!(null), json!(null)), (json!(""), json!(null)), (json!("å".repeat(40)), json!("å".repeat(40))),
        (json!("å".repeat(41)), json!(null)), (json!("Bio\nlogi"), json!(null)), (json!(7), json!(null))] {
        let result = validate_lesson_v2_result(&answer(vec![], subject.clone()), &payload()).unwrap();
        assert_eq!(result["subject"], expected, "{subject}");
    }
}

#[test]
fn the_shape_is_still_all_or_nothing_and_sections_must_be_grounded() {
    let good = answer(vec![], json!(null));
    for broken in [common::without(&good, "examHints"), common::without(&good, "subject"), with(&good, json!({ "examHints": {} })),
        with(&good, json!({ "highlights": [] })), common::without(&good, "sections")] {
        assert!(validate_lesson_v2_result(&broken, &payload()).is_err(), "{broken}");
    }
    let mut ungrounded = good.clone();
    ungrounded["sections"][0]["evidence"] = json!("finns inte");
    assert!(validate_lesson_v2_result(&ungrounded, &payload()).is_err(), "a section without a quote rejects the part, as in v1");
    // A v1 answer is not a v2 answer.
    let v1 = json!({ "candidates": [], "sections": good["sections"], "uncertainties": [] });
    assert!(validate_lesson_v2_result(&v1, &payload()).is_err());
}

fn envelope(value: &Value) -> Value {
    json!({ "choices": [{ "finish_reason": "stop", "message": { "role": "assistant", "content": value.to_string() } }] })
}

fn config() -> Config {
    Config { requests_per_minute: 60, lesson_interval_seconds: Some(120),
        ..load_config(&env(&[("MIO_AI_MODEL", MODEL), ("GROQ_API_KEY", "fixture-key"), ("MIO_GATEWAY_TOKEN", TOKEN)])).unwrap() }
}

#[tokio::test]
async fn the_v2_route_answers_with_hints_subject_and_its_own_prompt_version() {
    let notes = answer(vec![hint("Fotosyntesen", &[FIRST], "Det här kommer på provet")], json!("Biologi"));
    let provider = Provider::fixed(Upstream::json(&envelope(&notes)));
    let server = serve(config(), &provider).await;
    assert_eq!(server.post_with("/v2/lesson-notes", &payload(), &[("Authorization", "Bearer wrong")]).await.status, 401);
    assert_eq!(server.post("/v2/lesson-notes", &with(&payload(), json!({ "mode": "everyday" }))).await.status, 400);
    assert_eq!(server.post("/v1/lesson-notes", &payload()).await.error(), "invalid_json", "v1 refuses speaker roles as before");
    assert_eq!(provider.count(), 0);
    let response = server.post("/v2/lesson-notes", &payload()).await;
    assert_eq!(response.status, 200, "{}", response.body);
    let body = response.json();
    assert_eq!(body["examHints"], notes["examHints"]);
    assert_eq!(body["subject"], "Biologi");
    assert_eq!(body["metadata"], json!({ "provider": "groq", "model": MODEL, "promptVersion": LESSON_V2_PROMPT_VERSION, "lessonIntervalSeconds": 120 }));
    assert_eq!(response.header("x-mio-prompt-version"), Some(LESSON_V2_PROMPT_VERSION));
    let sent = provider.body(0);
    assert_eq!(sent["response_format"]["json_schema"]["name"], "mio_lesson_notes_v2");
    assert_eq!(sent["messages"][1]["content"], payload().to_string());
    // An answer in v1's shape is an invalid lesson result on v2.
    let v1 = Provider::fixed(Upstream::json(&envelope(&json!({ "candidates": [], "sections": notes["sections"], "uncertainties": [] }))));
    assert_eq!(serve(config(), &v1).await.post("/v2/lesson-notes", &payload()).await.error(), "invalid_lesson_result");
}

#[tokio::test]
async fn status_publishes_lesson_notes_v2_beside_v1_without_changing_the_revision() {
    let provider = Provider::fixed(Upstream::Fail);
    let server = serve(config(), &provider).await;
    let status = server.status_v2().await;
    let capabilities = status["tasks"]["lesson"]["capabilities"].as_array().unwrap();
    assert!(capabilities.contains(&json!("lesson-notes-v1")) && capabilities.contains(&json!("lesson-notes-v2")));
    for task in ["ask", "everyday"] {
        assert!(!status["tasks"][task]["capabilities"].as_array().unwrap().contains(&json!("lesson-notes-v2")));
    }
    assert_eq!(status["configurationRevision"], mio_gateway::status::configuration_revision(&config()));
}

/// The 180 s limit for a lesson on a profile that reasons is keyed on the task, so v2 has it too.
#[tokio::test(start_paused = true)]
async fn a_reasoning_v2_lesson_gets_180_seconds() {
    let reasoning = load_config(&env(&[("MIO_AI_PROVIDER", "mistral"), ("MIO_AI_MODEL", "mistral-small-2603"),
        ("MISTRAL_API_KEY", "fixturemistralkey0123456789abcdef"), ("MIO_GATEWAY_TOKEN", TOKEN),
        ("MIO_AI_TASK_PROFILES", r#"{"lesson":{"model":"mistral-large-4-0"}}"#),
        ("MIO_APPROVED_CANDIDATES", "mistral=mistral-small-2603,mistral=mistral-large-4-0")])).unwrap();
    for (config, limit) in [(reasoning, Duration::from_secs(180)), (config(), Duration::from_secs(40))] {
        let provider = Provider::fixed(Upstream::Hang);
        let started = tokio::time::Instant::now();
        let error = execute_generation(&config, Mode::LessonV2, &payload(), &Link(provider.clone()), &mut || Ok(()),
            &|| 1_795_176_000_000, &Spent::default()).await.err().unwrap();
        assert_eq!((error.status, error.code, started.elapsed()), (504, "upstream_timeout", limit));
        let sent = provider.body(0);
        if limit.as_secs() == 180 {
            assert_eq!(sent["max_tokens"], 12_000, "room for thinking as in v1");
        }
    }
}
