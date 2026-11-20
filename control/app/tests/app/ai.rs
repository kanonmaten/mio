//! The AI page against a fake helper: read the settings, change a model and a limit, see the
//! list of changes, save; the credit meter and reasoning levels from a made-up `/v2/status`.
//! Nothing reaches a real helper, gateway or provider.

use std::sync::{Arc, Mutex};

use gpui_kit::test::TestWindowExt as _;
use gpui_kit::{AppContext as _, Bounds, Entity, TestAppContext, WindowBounds, WindowOptions, px, size};
use mio_control::computer::ComputerBackend;
use mio_control::model::StatusModel;
use mio_control::operation::Backend;
use mio_control::shell::{Page, Shell};
use mio_control_core::command::{Command, Unit, UnitAction};
use mio_control_core::computer::Preferences;
use mio_control_core::settings::SettingsFile;
use mio_control_core::status::{GatewayStatus, Overview, UnitState};
use serde_json::{Value, json};

type Calls = Arc<Mutex<Vec<(Command, Option<Vec<u8>>)>>>;

fn settings() -> Value {
    json!({ "exists": true,
        "values": { "MIO_AI_PROVIDER": "groq", "MIO_AI_MODEL": "qwen/qwen3.8-27b", "MIO_REQUESTS_PER_MINUTE": "10",
            "MIO_TOKENS_PER_MINUTE": "8000", "MIO_TOKENS_PER_DAY": "190000", "MIO_LESSON_INTERVAL_SECONDS": "60", "PORT": "8787" },
        "secrets": { "GROQ_API_KEY": true, "ANTHROPIC_API_KEY": true, "MIO_GATEWAY_TOKEN": true } })
}

fn catalog() -> Value {
    json!({ "providers": ["groq", "anthropic", "mistral", "nvidia"],
        "models": [
            { "provider": "groq", "model": "qwen/qwen3.8-27b", "secretVariable": "GROQ_API_KEY", "temperature": "0" },
            { "provider": "anthropic", "model": "claude-haiku-5-5", "secretVariable": "ANTHROPIC_API_KEY", "temperature": "provider-default" },
            // A made-up reasoning pair reviewed for lessons only, in the shape the panel reads.
            { "provider": "mistral", "model": "mistral-large-test", "secretVariable": "MISTRAL_API_KEY", "reasoning": "high", "tasks": ["lesson"] }],
        "candidates": [{ "provider": "mistral", "model": "mistral-small-2603", "secretVariable": "MISTRAL_API_KEY", "blocked": "Kräver ett godkänt prov." }] })
}

/// A made-up `/v2/status` after the grilling: Large reasons for lessons, $17 of $20 spent.
fn gateway_status() -> Value {
    json!({ "tasks": {
            "ask": { "provider": "groq", "model": "qwen/qwen3.8-27b", "reasoning": "off", "schemaDialect": "strict-json-schema" },
            "everyday": { "provider": "groq", "model": "qwen/qwen3.8-27b", "reasoning": "off", "schemaDialect": "strict-json-schema" },
            "lesson": { "provider": "mistral", "model": "mistral-large-test", "reasoning": "high", "schemaDialect": "json-schema" } },
        "usage": { "month": "2026-11", "currency": "USD", "estimatedCost": 17.0, "entries": [
            { "task": "lesson", "provider": "mistral", "model": "mistral-large-test", "requests": 400, "inputTokens": 9000000,
              "cachedInputTokens": 0, "outputTokens": 5000000, "reasoningTokens": 2000000, "estimatedCost": 17.0, "pricesAsOf": "2026-11-20" }] } })
}

fn open(cx: &mut TestAppContext) -> (gpui_kit::AnyWindowHandle, Entity<Shell>, Calls) {
    let (handle, shell, calls, _) = open_with(cx, None);
    (handle, shell, calls)
}

/// Opens the AI page with an optional gateway status. The panel's preferences go to a temporary
/// folder, returned so the test can read what the credit limit field saved.
fn open_with(cx: &mut TestAppContext, gateway: Option<GatewayStatus>) -> (gpui_kit::AnyWindowHandle, Entity<Shell>, Calls, tempfile::TempDir) {
    cx.update(gpui_kit::init);
    cx.update(mio_control::theme::init);
    let calls: Calls = Arc::default();
    let recorded = calls.clone();
    cx.update(|cx| {
        cx.set_global(Backend {
            helper: Arc::new(move |command: &Command, stdin: Option<&[u8]>| {
                recorded.lock().unwrap().push((command.clone(), stdin.map(<[u8]>::to_vec)));
                Ok(match command {
                    Command::ReadSettings(SettingsFile::Gateway) => settings().to_string().into_bytes(),
                    Command::TrialModel { .. } => json!({ "passed": true, "tasks": [{ "task": "ask", "ok": true, "milliseconds": 900 }] }).to_string().into_bytes(),
                    _ => b"{}".to_vec(),
                })
            }),
            catalog: Arc::new(|| Ok(catalog().to_string().into_bytes())),
        })
    });
    let folder = tempfile::tempdir().unwrap();
    let preferences = folder.path().join("mio-control/installningar");
    cx.update(|cx| {
        cx.set_global(ComputerBackend {
            inhibit: Arc::new(|| Err("inte i testet".into())),
            preferences: Some(preferences),
            autostart: None,
        })
    });
    let status = cx.update(|cx| cx.new(|_| StatusModel::default()));
    if let Some(gateway) = gateway {
        let overview = Overview { gateway_unit: UnitState::Running, gateway_health: Some(true), gateway: Some(gateway), ..Default::default() };
        cx.update(|cx| status.update(cx, |status, cx| status.apply(overview, cx)));
    }
    let (handle, shell) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::new(Default::default(), size(px(900.), px(2000.))))),
                ..Default::default()
            },
            cx,
            |window, cx| cx.new(|cx| Shell::new(status, window, cx)),
        )
        .expect("open test window")
    });
    cx.update(|cx| shell.update(cx, |shell, cx| shell.show(Page::Ai, cx)));
    (handle, shell, calls, folder)
}

#[gpui_kit::test]
fn choose_a_model_and_a_limit_see_the_changes_and_save(cx: &mut TestAppContext) {
    let (handle, _, calls) = open(cx);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        // Nothing is read (no password) until the user asks to change something.
        assert!(window.try_find("changes").is_none());
        window.click("edit-ai", cx);
    })
    .unwrap();
    cx.run_until_parked();
    assert!(matches!(calls.lock().unwrap()[0].0, Command::ReadSettings(SettingsFile::Gateway)));
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("changes").label(), Some("Inga ändringar."));
        // Lesson notes on Anthropic, chosen with the keyboard in the menu: same, Groq, Anthropic.
        window.click("ai-task-lesson", cx);
        window.press("down", cx);
        window.press("down", cx);
        window.press("enter", cx);
    })
    .unwrap();
    cx.run_until_parked();
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("changes").label(), Some("1 ändringar"), "the lesson model");
        // Twenty requests per minute instead of ten.
        window.click("limit-MIO_REQUESTS_PER_MINUTE", cx);
        window.press("ctrl-a", cx);
        window.input("20", cx);
    })
    .unwrap();
    cx.run_until_parked();
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("changes").label(), Some("2 ändringar"));
        window.click("save-ai", cx);
    })
    .unwrap();
    cx.run_until_parked();
    let calls = calls.lock().unwrap();
    let (write, stdin) = calls.iter().find(|(command, _)| matches!(command, Command::WriteSettings(SettingsFile::Gateway))).expect("settings were written");
    assert!(matches!(write, Command::WriteSettings(_)));
    let request: Value = serde_json::from_slice(stdin.as_ref().unwrap()).unwrap();
    assert_eq!(request["set"]["MIO_REQUESTS_PER_MINUTE"], "20");
    let profiles: Value = serde_json::from_str(request["set"]["MIO_AI_TASK_PROFILES"].as_str().unwrap()).unwrap();
    assert_eq!(profiles, json!({ "lesson": { "provider": "anthropic", "model": "claude-haiku-5-5" } }));
    // Then the gateway is restarted, after the write and never before it.
    let write_at = calls.iter().position(|(command, _)| matches!(command, Command::WriteSettings(_))).unwrap();
    let restart_at = calls.iter().position(|(command, _)| *command == Command::Unit(UnitAction::Restart, Unit::Gateway)).unwrap();
    assert!(restart_at > write_at);
}

#[gpui_kit::test]
fn an_invalid_limit_blocks_saving(cx: &mut TestAppContext) {
    let (handle, _, calls) = open(cx);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.click("edit-ai", cx);
    })
    .unwrap();
    cx.run_until_parked();
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.click("limit-MIO_REQUESTS_PER_MINUTE", cx);
        window.press("ctrl-a", cx);
        window.input("61", cx);
    })
    .unwrap();
    cx.run_until_parked();
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.click("save-ai", cx);
    })
    .unwrap();
    cx.run_until_parked();
    assert!(!calls.lock().unwrap().iter().any(|(command, _)| matches!(command, Command::WriteSettings(_))));
}

#[gpui_kit::test]
fn a_candidate_is_tried_only_when_the_user_presses_prova(cx: &mut TestAppContext) {
    let (handle, _, calls) = open(cx);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.click("edit-ai", cx);
    })
    .unwrap();
    cx.run_until_parked();
    assert!(!calls.lock().unwrap().iter().any(|(command, _)| matches!(command, Command::TrialModel { .. })));
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.click("try-mistral-mistral-small-2603", cx);
    })
    .unwrap();
    cx.run_until_parked();
    assert!(calls.lock().unwrap().iter().any(|(command, _)| *command == Command::TrialModel { provider: "mistral", model: "mistral-small-2603".into() }));
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("trial-report").label(), Some("Provet godkänt"));
    })
    .unwrap();
}

#[gpui_kit::test]
fn the_credit_meter_turns_yellow_at_eighty_percent_and_follows_the_typed_limit(cx: &mut TestAppContext) {
    let (handle, _, calls, folder) = open_with(cx, Some(GatewayStatus::parse(&gateway_status())));
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("credit-meter").label(), Some("Nära gränsen. $17,00 av $20,00 i 2026-11 (85 %)"));
        // The lesson reasons; the gateway says so per task.
        assert_eq!(window.find("reasoning-lesson").label(), Some("Resonerar (hög)"));
        assert_eq!(window.find("reasoning-ask").label(), Some("Resonerar inte"));
        window.click("credit-limit", cx);
        window.press("ctrl-a", cx);
        window.input("15", cx);
    })
    .unwrap();
    cx.run_until_parked();
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("credit-meter").label(), Some("Över gränsen. $17,00 av $15,00 i 2026-11 (113 %)"));
        window.press("ctrl-a", cx);
        window.input("100", cx);
    })
    .unwrap();
    cx.run_until_parked();
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("credit-meter").label(), Some("Inom gränsen. $17,00 av $100,00 i 2026-11 (17 %)"));
        // Something that is not an amount keeps the saved limit.
        window.press("ctrl-a", cx);
        window.input("mycket", cx);
    })
    .unwrap();
    cx.run_until_parked();
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("credit-meter").label(), Some("Inom gränsen. $17,00 av $100,00 i 2026-11 (17 %)"));
    })
    .unwrap();
    assert_eq!(Preferences::load(&folder.path().join("mio-control/installningar")).credit_limit_cents, 10_000);
    // The limit is the panel's own: nothing went to the helper or the gateway.
    assert!(calls.lock().unwrap().is_empty());
}

#[gpui_kit::test]
fn an_older_gateway_shows_no_meter_and_no_reasoning(cx: &mut TestAppContext) {
    let older = GatewayStatus::parse(&json!({ "tasks": { "ask": { "provider": "groq", "model": "qwen/qwen3.8-27b" } } }));
    let (handle, _, _, _) = open_with(cx, Some(older));
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert!(window.try_find("credit-meter").is_none());
        assert!(window.try_find("reasoning-ask").is_none());
        assert!(window.try_find("credit-limit").is_some(), "the limit can still be set");
    })
    .unwrap();
}

#[gpui_kit::test]
fn mistral_is_first_to_try_with_its_cost_and_large_is_offered_only_for_lessons(cx: &mut TestAppContext) {
    let (handle, _, calls) = open(cx);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.click("edit-ai", cx);
    })
    .unwrap();
    cx.run_until_parked();
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        let top = |id: &str| window.find(id.to_owned()).bounds().origin.y;
        assert!(top("try-mistral-mistral-small-2603") < top("try-mistral-mistral-large-test"));
        assert!(top("try-mistral-mistral-large-test") < top("try-groq-qwen/qwen3.8-27b"));
        let cost = window.find("trial-cost-mistral-mistral-small-2603");
        let cost = cost.label().unwrap();
        assert!(cost.starts_with("Går till Mistral: tre korta påhittade anrop"), "{cost}");
        assert!(cost.contains("under en cent (priser 2026-11-20)"), "{cost}");
        // Lessons: same, Groq, Anthropic, Mistral Large; the last one is only here.
        window.click("ai-task-lesson", cx);
        window.press("down", cx);
        window.press("down", cx);
        window.press("down", cx);
        window.press("enter", cx);
    })
    .unwrap();
    cx.run_until_parked();
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("changes").label(), Some("1 ändringar"));
    })
    .unwrap();
    // Seeing the cost sends nothing; only Prova does.
    assert!(!calls.lock().unwrap().iter().any(|(command, _)| matches!(command, Command::TrialModel { .. })));
}
