//! The AI page against a fake helper: read the settings, change a model and a limit, see the
//! list of changes, save. Nothing reaches a real helper, gateway or provider.

use std::sync::{Arc, Mutex};

use gpui_kit::test::TestWindowExt as _;
use gpui_kit::{AppContext as _, Bounds, Entity, TestAppContext, WindowBounds, WindowOptions, px, size};
use mio_control::model::StatusModel;
use mio_control::operation::Backend;
use mio_control::shell::{Page, Shell};
use mio_control_core::command::{Command, Unit, UnitAction};
use mio_control_core::settings::SettingsFile;
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
            { "provider": "anthropic", "model": "claude-haiku-5-5", "secretVariable": "ANTHROPIC_API_KEY", "temperature": "provider-default" }],
        "candidates": [{ "provider": "mistral", "model": "mistral-small-2603", "secretVariable": "MISTRAL_API_KEY", "blocked": "Kräver ett godkänt prov." }] })
}

fn open(cx: &mut TestAppContext) -> (gpui_kit::AnyWindowHandle, Entity<Shell>, Calls) {
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
    let status = cx.update(|cx| cx.new(|_| StatusModel::default()));
    let (handle, shell) = cx.update(|cx| {
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::new(Default::default(), size(px(900.), px(1400.))))),
                ..Default::default()
            },
            cx,
            |window, cx| cx.new(|cx| Shell::new(status, window, cx)),
        )
        .expect("open test window")
    });
    cx.update(|cx| shell.update(cx, |shell, cx| shell.show(Page::Ai, cx)));
    (handle, shell, calls)
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
